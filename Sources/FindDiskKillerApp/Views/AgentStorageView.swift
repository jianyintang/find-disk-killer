import AppKit
import FindDiskKillerCore
import SwiftUI

let agentStorageNonProjectDirectoryName = "Non-project directory"

func localizedAgentStorageProjectName(_ project: String) -> String {
    project == agentStorageNonProjectDirectoryName ? L10n.text(project) : project
}

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

struct AgentStorageTimeRange: Equatable, Hashable, Sendable {
    static let minimumInactiveDays = 1
    static let maximumInactiveDays = 365
    static let all = Self(inactiveDays: nil)
    static let oneDay = Self.olderThan(days: 1)
    static let sevenDays = Self.olderThan(days: 7)
    static let thirtyDays = Self.olderThan(days: 30)
    static let ninetyDays = Self.olderThan(days: 90)
    static let presets = [oneDay, sevenDays, thirtyDays, ninetyDays]

    let inactiveDays: Int?

    static func olderThan(days: Int) -> Self {
        Self(inactiveDays: min(maximumInactiveDays, max(minimumInactiveDays, days)))
    }

    var title: String {
        inactiveDays.map { L10n.format("%d 天前", $0) } ?? L10n.text("全部时间")
    }

    var inactiveTitle: String? {
        inactiveDays.map { L10n.format("超过 %d 天未活动", $0) }
    }

    func cutoffDate(relativeTo referenceDate: Date) -> Date? {
        guard let inactiveDays else { return nil }
        return Calendar.current.date(byAdding: .day, value: -inactiveDays, to: referenceDate)
    }

    func includes(updatedAt: Date, relativeTo referenceDate: Date) -> Bool {
        guard let cutoff = cutoffDate(relativeTo: referenceDate) else { return true }
        return updatedAt < cutoff
    }
}

extension AgentStorageThreadFamily {
    func largestSubagents(limit: Int) -> [AgentStorageThreadNode] {
        guard limit > 0 else { return [] }
        return subagents.sorted { lhs, rhs in
            if lhs.attributedBytes != rhs.attributedBytes {
                return lhs.attributedBytes > rhs.attributedBytes
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

private struct AgentStorageCleanupCompletion: Equatable {
    let provider: AgentStorageProvider
    let succeededCount: Int
    let skippedCount: Int
    let failedCount: Int
    let measuredReleasedBytes: UInt64

    init(provider: AgentStorageProvider, result: AgentStorageCleanupResult) {
        self.provider = provider
        succeededCount = result.succeededCount
        skippedCount = result.skippedCount
        failedCount = result.failedCount
        measuredReleasedBytes = result.measuredReleasedBytes
    }
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

private struct AgentStorageSnapshotIndex: Sendable {
    let providerOverviewItems: [AgentStorageProviderOverviewItem]
    let dataset: AgentStorageProviderDataset?
    let familyIndex: [String: AgentStorageThreadFamily]
    let detailIndex: [String: AgentStorageResolvedDetail]
    let cleanupBytesByFamilyID: [String: UInt64]
}

private enum AgentStorageIndexBuilder {
    static func build(
        snapshot: AgentStorageSnapshot,
        provider: AgentStorageProvider?
    ) -> AgentStorageSnapshotIndex {
        let overviewItems = snapshot.providers.map {
            AgentStorageProviderOverviewItem(
                summary: $0,
                totalAgentBytes: snapshot.totalBytes
            )
        }
        guard let provider,
              let dataset = snapshot.dataset(for: provider) else {
            return AgentStorageSnapshotIndex(
                providerOverviewItems: overviewItems,
                dataset: nil,
                familyIndex: [:],
                detailIndex: [:],
                cleanupBytesByFamilyID: [:]
            )
        }

        let families = Dictionary(uniqueKeysWithValues: dataset.families.map { ($0.id, $0) })
        var details: [String: AgentStorageResolvedDetail] = [:]
        var cleanupBytesByFamilyID: [String: UInt64] = [:]
        details.reserveCapacity(
            dataset.families.count
                + dataset.families.reduce(0) { $0 + $1.subagents.count }
                + dataset.globalItems.count
                + dataset.unattributedItems.count
        )
        for family in dataset.families {
            details[family.id] = .family(family)
            cleanupBytesByFamilyID[family.id] = AgentStorageCleanupValidator
                .officialArtifacts(for: family)
                .reduce(0) {
                    let sum = $0.addingReportingOverflow($1.allocatedBytes)
                    return sum.overflow ? .max : sum.partialValue
                }
            for subagent in family.subagents {
                details[subagent.id] = .subagent(subagent, family)
            }
        }
        for item in dataset.globalItems { details[item.id] = .global(item) }
        for item in dataset.unattributedItems { details[item.id] = .unattributed(item) }
        return AgentStorageSnapshotIndex(
            providerOverviewItems: overviewItems,
            dataset: dataset,
            familyIndex: families,
            detailIndex: details,
            cleanupBytesByFamilyID: cleanupBytesByFamilyID
        )
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
    let usesMockTitles: Bool

    init(
        scope: AgentStorageScope,
        dataset: AgentStorageProviderDataset,
        scannedAt: Date,
        archiveFilter: AgentStorageArchiveFilter,
        timeRange: AgentStorageTimeRange,
        selectedProject: String?,
        selectedGlobalCategory: AgentStorageGlobalCategory?,
        selectedUnattributedReason: AgentStorageUnattributedReason?,
        query: String,
        hidesPrivateDetails: Bool,
        expandedFamilies: Set<String>,
        chatPageIndex: Int,
        chatPageSize: Int,
        chatSortRules: [AgentStorageChatSortRule],
        globalSortRules: [AgentStorageGlobalSortRule],
        unattributedSortRules: [AgentStorageUnattributedSortRule],
        usesMockTitles: Bool = false
    ) {
        self.scope = scope
        self.dataset = dataset
        self.scannedAt = scannedAt
        self.archiveFilter = archiveFilter
        self.timeRange = timeRange
        self.selectedProject = selectedProject
        self.selectedGlobalCategory = selectedGlobalCategory
        self.selectedUnattributedReason = selectedUnattributedReason
        self.query = query
        self.hidesPrivateDetails = hidesPrivateDetails
        self.expandedFamilies = expandedFamilies
        self.chatPageIndex = chatPageIndex
        self.chatPageSize = chatPageSize
        self.chatSortRules = chatSortRules
        self.globalSortRules = globalSortRules
        self.unattributedSortRules = unattributedSortRules
        self.usesMockTitles = usesMockTitles
    }
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

enum AgentStorageBatchSelectionEngine {
    enum PageSelectionState: Equatable {
        case none
        case partial
        case all
    }

    static func pageFamilyIDs(in rows: [AgentStorageChatRow]) -> Set<String> {
        Set(rows.lazy.filter(\.isFamily).map(\.familyID))
    }

    static func pageSelectionState(
        selectedIDs: Set<String>,
        pageFamilyIDs: Set<String>
    ) -> PageSelectionState {
        guard !pageFamilyIDs.isEmpty else { return .none }
        let selectedCount = pageFamilyIDs.intersection(selectedIDs).count
        if selectedCount == 0 { return .none }
        if selectedCount == pageFamilyIDs.count { return .all }
        return .partial
    }

    static func togglingCurrentPage(
        selectedIDs: Set<String>,
        pageFamilyIDs: Set<String>
    ) -> Set<String> {
        guard !pageFamilyIDs.isEmpty else { return selectedIDs }
        var result = selectedIDs
        if pageFamilyIDs.isSubset(of: selectedIDs) {
            result.subtract(pageFamilyIDs)
        } else {
            result.formUnion(pageFamilyIDs)
        }
        return result
    }

    static func eligibleFamilyIDs(
        in families: [AgentStorageThreadFamily],
        timeRange: AgentStorageTimeRange,
        relativeTo referenceDate: Date
    ) -> Set<String> {
        guard timeRange != .all else { return [] }
        return Set(families.lazy.filter {
            timeRange.includes(updatedAt: $0.updatedAt, relativeTo: referenceDate)
        }.map(\.id))
    }
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
        var timeFamilies: [AgentStorageThreadFamily] = []
        timeFamilies.reserveCapacity(request.dataset.families.count)
        for (index, family) in request.dataset.families.enumerated() {
            if index.isMultiple(of: 32) { try Task.checkCancellation() }
            if request.timeRange.includes(
                updatedAt: family.updatedAt,
                relativeTo: request.scannedAt
            ) {
                timeFamilies.append(family)
            }
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
                hidesPrivateDetails: request.hidesPrivateDetails,
                usesMockTitles: request.usesMockTitles
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
                        hidesPrivateDetails: request.hidesPrivateDetails,
                        usesMockTitles: request.usesMockTitles
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
        let visibleTitle = visibleFamilyTitle(
            family,
            hidesPrivateDetails: request.hidesPrivateDetails,
            usesMockTitles: request.usesMockTitles
        )
        if visibleTitle.localizedCaseInsensitiveContains(request.query) {
            return true
        }
        if request.hidesPrivateDetails {
            return family.provider.displayName.localizedCaseInsensitiveContains(request.query)
                || family.nativeThreadID.localizedCaseInsensitiveContains(request.query)
        }
        return family.project.localizedCaseInsensitiveContains(request.query)
            || family.nativeThreadID.localizedCaseInsensitiveContains(request.query)
    }

    private static func nodeMatches(
        _ node: AgentStorageThreadNode,
        family: AgentStorageThreadFamily,
        request: AgentStorageProjectionRequest
    ) -> Bool {
        let visibleTitle = visibleNodeTitle(
            node,
            family: family,
            hidesPrivateDetails: request.hidesPrivateDetails,
            usesMockTitles: request.usesMockTitles
        )
        if visibleTitle.localizedCaseInsensitiveContains(request.query) {
            return true
        }
        if request.hidesPrivateDetails {
            return node.nativeID.localizedCaseInsensitiveContains(request.query)
        }
        return node.nativeID.localizedCaseInsensitiveContains(request.query)
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
                    visibleFamilyTitle(
                        lhs,
                        hidesPrivateDetails: request.hidesPrivateDetails,
                        usesMockTitles: request.usesMockTitles
                    ),
                    visibleFamilyTitle(
                        rhs,
                        hidesPrivateDetails: request.hidesPrivateDetails,
                        usesMockTitles: request.usesMockTitles
                    )
                )
            case .updatedAt: comparison = compare(lhs.updatedAt, rhs.updatedAt)
            case .subagentCount: comparison = compare(lhs.subagentCount, rhs.subagentCount)
            case .allocatedBytes: comparison = compare(lhs.attributedBytes, rhs.attributedBytes)
            case .id: comparison = compare(lhs.id, rhs.id)
            }
            if comparison != 0 { return rule.isReverse ? comparison > 0 : comparison < 0 }
        }
        return lhs.id < rhs.id
    }

    private static func visibleFamilyTitle(
        _ family: AgentStorageThreadFamily,
        hidesPrivateDetails: Bool,
        usesMockTitles: Bool
    ) -> String {
        if usesMockTitles {
            return AgentStorageMockTitleCatalog.title(
                provider: family.provider,
                nativeID: family.nativeThreadID,
                isSubagent: false
            )
        }
        guard hidesPrivateDetails else { return family.title }
        return "\(family.provider.displayName) \(L10n.text("聊天")) · \(L10n.date(family.updatedAt, date: .abbreviated, time: .omitted))"
    }

    private static func visibleNodeTitle(
        _ node: AgentStorageThreadNode,
        family: AgentStorageThreadFamily,
        hidesPrivateDetails: Bool,
        usesMockTitles: Bool
    ) -> String {
        if usesMockTitles {
            return AgentStorageMockTitleCatalog.title(
                provider: family.provider,
                nativeID: node.nativeID,
                isSubagent: true
            )
        }
        return hidesPrivateDetails ? L10n.text("子代理") : node.title
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
    let initialProvider: AgentStorageProvider?
    let allowsAnalysisActions: Bool
    let nodeRuntime: ClaudeNodeRuntimeStatusModel
    let providerExitAction: (() -> Void)?
    let cleanupDidAffectProviders: ((Set<AgentStorageProvider>) -> Void)?
    @AppStorage(AgentStoragePreferences.hidePrivateDetailsKey) private var hidesPrivateDetails = false
    @AppStorage(AgentStoragePreferences.mockTitlesKey) private var usesMockTitles = false
    @State private var selectedProvider: AgentStorageProvider?
    @State private var scope: AgentStorageScope = .chats
    @State private var archiveFilter: AgentStorageArchiveFilter = .all
    @State private var timeRange: AgentStorageTimeRange = .all
    @State private var showsTimeRangePopover = false
    @State private var showsFilterPopover = false
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
    @State private var cleanupBytesByFamilyID: [String: UInt64] = [:]
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
    @State private var indexGeneration = 0
    @State private var indexTask: Task<Void, Never>?
    @State private var cleanupSelectedIDs: Set<String> = []
    @State private var pendingCleanupSynchronizationIDsByProvider: [AgentStorageProvider: Set<String>] = [:]
    @State private var cleanupReview: AgentStorageCleanupReview?
    @State private var isCleanupReviewUpdating = false
    @State private var cleanupReviewGeneration = 0
    @State private var cleanupReviewTask: Task<Void, Never>?
    @State private var cleanupSession: AgentStorageCleanupSession?
    @State private var cleanupCompletion: AgentStorageCleanupCompletion?
    @State private var qualityDetails: AgentStorageQualityDetails?
    @FocusState private var tableHasFocus: Bool
    @FocusState private var focusedProvider: AgentStorageProvider?
    @AccessibilityFocusState private var accessibilityFocusedProvider: AgentStorageProvider?
    @AccessibilityFocusState private var tableAccessibilityFocus: Bool

    init(
        model: AgentStorageModel,
        initialProvider: AgentStorageProvider? = nil,
        allowsAnalysisActions: Bool = true,
        nodeRuntime: ClaudeNodeRuntimeStatusModel,
        providerExitAction: (() -> Void)? = nil,
        cleanupDidAffectProviders: ((Set<AgentStorageProvider>) -> Void)? = nil
    ) {
        self.model = model
        self.initialProvider = initialProvider
        self.allowsAnalysisActions = allowsAnalysisActions
        self.nodeRuntime = nodeRuntime
        self.providerExitAction = providerExitAction
        self.cleanupDidAffectProviders = cleanupDidAffectProviders
        _selectedProvider = State(initialValue: initialProvider)
        _isProjecting = State(initialValue: initialProvider != nil)
    }

    var body: some View {
        lifecycleContent
    }

    private var analysisAction: (() -> Void)? {
        guard allowsAnalysisActions else { return nil }
        return { model.startAnalysis() }
    }

    private var refreshAction: (() -> Void)? {
        guard allowsAnalysisActions else { return nil }
        return { model.isScanning ? model.stop() : model.startAnalysis() }
    }

    private var cleanupReanalysisAction: (() -> Void)? {
        guard allowsAnalysisActions else { return nil }
        return {
            cleanupCompletion = nil
            model.startAnalysis()
        }
    }

    private var lifecycleContent: some View {
        presentationContent
        .task { model.enterFeature() }
        .task(id: selectedProvider) {
            guard selectedProvider == .claude else { return }
            nodeRuntime.refresh()
        }
        .onChange(of: model.snapshotRevision, initial: true) { _, _ in
            scheduleSnapshotIndex(model.snapshot)
        }
        .onChange(of: model.resultRevisionsByProvider) { oldValue, newValue in
            let updatedProviders = Set(newValue.keys).filter {
                newValue[$0] != oldValue[$0]
            }
            for provider in updatedProviders {
                pendingCleanupSynchronizationIDsByProvider.removeValue(forKey: provider)
            }
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
                scheduleProjection(debounce: .milliseconds(80))
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
            if scope != .chats { resetCleanupSelection() }
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
        .onChange(of: usesMockTitles) { _, _ in
            resetChatPage()
            scheduleProjection()
        }
        .onChange(of: chatSortOrder) { _, _ in
            resetChatPage()
            scheduleProjection()
        }
        .onChange(of: globalSortOrder) { _, _ in scheduleProjection() }
        .onChange(of: unattributedSortOrder) { _, _ in scheduleProjection() }
        .onDisappear {
            projectionTask?.cancel()
            indexTask?.cancel()
            cleanupReviewTask?.cancel()
        }
        .onChange(of: cleanupSelectedIDs) { _, _ in scheduleCleanupReview() }
        .onChange(of: selection) { _, newValue in
            guard let newValue, resolvedDetail(id: newValue) != nil else { return }
            presentDetail(id: newValue)
        }
    }

    private var presentationContent: some View {
        navigationContent
        .sheet(item: $compactDetail) { detail in
            AgentStorageCompactDetail(
                detail: resolvedDetail(id: detail.id),
                hidesPrivateDetails: hidesPrivateDetails
            )
            .frame(minWidth: 560, minHeight: 560)
            .onDisappear { tableHasFocus = true }
        }
        .sheet(item: $cleanupSession) { session in
            AgentStorageCleanupReviewView(
                session: session,
                close: { cleanupSession = nil },
                didFinish: { result in handleCleanupCompletion(result) },
                hasRemainingItems: hasRemainingCleanupItems(after: session)
            )
            .interactiveDismissDisabled(session.phase == .deleting)
        }
        .sheet(item: $qualityDetails) { details in
            AgentStorageQualityDetailsView(
                details: details,
                hidesPrivateDetails: hidesPrivateDetails,
                reanalyze: analysisAction
            )
        }
    }

    private var navigationContent: some View {
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
            refresh: refreshAction,
            back: exitAction
        ))
        .modifier(AgentStorageConditionalSearch(
            isEnabled: selectedProvider != nil,
            searchText: $searchText,
            prompt: searchPrompt
        ))
        .toolbar { featureToolbar }
    }

    @ToolbarContentBuilder
    private var featureToolbar: some ToolbarContent {
        if selectedProvider != nil {
            ToolbarItem(placement: .navigation) {
                Button(action: dismissDetailOrLeaveProvider) {
                    Image(systemName: "chevron.left")
                }
                .help(providerBackTitle)
                .accessibilityLabel(providerBackTitle)
            }

        }

        ToolbarItemGroup(placement: .primaryAction) {
            if selectedProvider != nil {
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

            if allowsAnalysisActions && (model.snapshot != nil || model.isScanning) {
                Button {
                    model.isScanning ? model.stop() : model.startAnalysis()
                } label: {
                    Image(systemName: model.isScanning ? "stop.fill" : "arrow.clockwise")
                }
                .help(L10n.text(model.isScanning ? "停止本次扫描" : "重新分析"))
                .accessibilityLabel(L10n.text(model.isScanning ? "停止本次扫描" : "重新分析"))
                .accessibilityIdentifier("agent-storage-refresh")
            }
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
        clearScopeFilters()
    }

    private func clearScopeFilters() {
        archiveFilter = .all
        selectedProject = nil
        selectedGlobalCategory = nil
        selectedUnattributedReason = nil
    }

    private var scopeFilterCount: Int {
        switch scope {
        case .chats:
            return (archiveFilter == .all ? 0 : 1) + (selectedProject == nil ? 0 : 1)
        case .global:
            return selectedGlobalCategory == nil ? 0 : 1
        case .unattributed:
            return selectedUnattributedReason == nil ? 0 : 1
        }
    }

    private var filterResultCount: Int {
        switch scope {
        case .chats: chatPagination.totalItems
        case .global: visibleGlobalItems.count
        case .unattributed: visibleUnattributedItems.count
        }
    }

    private var exitAction: (() -> Void)? {
        selectedProvider == nil ? nil : { dismissDetailOrLeaveProvider() }
    }

    private var providerBackTitle: String {
        providerExitAction == nil ? L10n.text("AI 空间") : L10n.text("返回空间地图")
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
                Label(L10n.text("未检测到 Codex、Claude 或 OpenCode 数据"), systemImage: "externaldrive.badge.questionmark")
            } description: {
                Text(L10n.text("分析 Codex、Claude 和 OpenCode 的聊天、子代理与全局运行时"))
            } actions: {
                if allowsAnalysisActions {
                    Button(L10n.text("重新分析")) { model.startAnalysis() }
                        .buttonStyle(AppActionButtonStyle(kind: .primary))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        } else if let cleanupCompletion {
            AgentStorageCleanupCompletedView(
                completion: cleanupCompletion,
                reanalyze: cleanupReanalysisAction
            )
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
            if !selectedProviderSources.isEmpty {
                Divider()
                AgentStorageLocationStrip(
                    sources: selectedProviderSources,
                    hidesPrivateDetails: hidesPrivateDetails
                )
            }
            if selectedProvider == .claude {
                Divider()
                ClaudeNodeRuntimeBar(model: nodeRuntime)
            }
            Divider()
            scopeActionBar
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

    private var scopeActionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                scopeViewControls
                Spacer(minLength: 16)
                scopeManagementControls
            }
            VStack(alignment: .leading, spacing: 8) {
                scopeViewControls
                if scope == .chats {
                    HStack {
                        Spacer(minLength: 0)
                        scopeManagementControls
                    }
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(minHeight: 48)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.24))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-storage-scope-actions")
    }

    @ViewBuilder
    private var scopeViewControls: some View {
        HStack(spacing: 0) {
            if scope == .chats {
                Button {
                    showsTimeRangePopover.toggle()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: timeRange == .all ? "clock" : "calendar.badge.clock")
                            .foregroundStyle(timeRange == .all ? Color.secondary : Color.accentColor)
                        Text(timeRange.inactiveTitle ?? L10n.text("全部时间"))
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(
                        timeRange == .all ? Color.clear : Color.accentColor.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(AgentStorageCompactToolbarButtonStyle())
                .popover(isPresented: $showsTimeRangePopover, arrowEdge: .bottom) {
                    AgentStorageAgeFilterPopover(
                        range: $timeRange,
                        scannedAt: model.snapshot?.scannedAt ?? .now,
                        summary: visibleChatSummary,
                        isUpdating: isProjecting
                    )
                }
                .help(L10n.text("按最后活动时间筛选聊天"))
                .accessibilityLabel(L10n.text("未活动时间门槛"))
                .accessibilityValue(
                    timeRange.inactiveTitle ?? L10n.text("显示全部聊天")
                )
                .accessibilityIdentifier("agent-storage-time-range")

                Divider()
                    .frame(height: 16)
            }

            Button {
                showsFilterPopover.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: scopeFilterCount > 0
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                        .foregroundStyle(scopeFilterCount > 0 ? Color.accentColor : Color.secondary)
                    Text(L10n.text("筛选"))
                        .foregroundStyle(.primary)
                    if scopeFilterCount > 0 {
                        Text(L10n.number(scopeFilterCount))
                            .font(.caption2.monospacedDigit().weight(.bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Color.accentColor, in: Circle())
                    }
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(
                    scopeFilterCount > 0 ? Color.accentColor.opacity(0.1) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(AgentStorageCompactToolbarButtonStyle())
            .popover(isPresented: $showsFilterPopover, arrowEdge: .bottom) {
                AgentStorageFilterPopover(
                    scope: scope,
                    archiveFilter: $archiveFilter,
                    selectedProject: $selectedProject,
                    selectedGlobalCategory: $selectedGlobalCategory,
                    selectedUnattributedReason: $selectedUnattributedReason,
                    projects: availableProjects,
                    hidesPrivateDetails: hidesPrivateDetails,
                    resultCount: filterResultCount,
                    isUpdating: isProjecting,
                    clear: clearScopeFilters
                )
            }
            .help(L10n.text("筛选 AI Agent"))
            .accessibilityLabel(L10n.text("筛选 AI Agent"))
            .accessibilityValue(L10n.format("%d 个筛选条件", scopeFilterCount))
            .accessibilityIdentifier("agent-storage-filter")
        }
        .padding(2)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.72),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.58))
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var scopeManagementControls: some View {
        if scope == .chats {
            cleanupSelectionControls
        }
    }

    private var cleanupSelectionControls: some View {
        HStack(spacing: 6) {
            Menu {
                Button(action: toggleCleanupCurrentPage) {
                    Label(
                        cleanupCurrentPageIsSelected ? L10n.text("取消选择本页") : L10n.text("选择本页"),
                        systemImage: cleanupCurrentPageIsSelected ? "checkmark.square.fill" : "square"
                    )
                }
                Button(action: toggleCleanupAllMatching) {
                    Label(
                            cleanupAllMatchingAreSelected
                                ? L10n.text("取消选择全部结果")
                                : L10n.format("选择全部 %d 个结果", cleanupAllMatchingIDs.count),
                        systemImage: cleanupAllMatchingAreSelected ? "checkmark.square.fill" : "square.stack.3d.up"
                    )
                }
                Divider()
                Button(L10n.text("清除选择"), systemImage: "xmark") {
                    cleanupSelectedIDs = []
                }
                .disabled(cleanupSelectedIDs.isEmpty)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: cleanupSelectedIDs.isEmpty ? "checkmark.circle" : "checkmark.circle.fill")
                    Text(L10n.format("已选 %d 项", cleanupSelectedIDs.count))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)

            Button(action: presentCleanupReview) {
                Label(L10n.text("检查并清理"), systemImage: "checkmark.shield")
            }
            .buttonStyle(AppActionButtonStyle(kind: .primary, size: .compact))
            .disabled(
                cleanupReview == nil
                    || isCleanupReviewUpdating
            )
            .help(L10n.text("最终提交前会再次核验活动状态和官方清理能力。"))
            .accessibilityIdentifier("agent-storage-review-cleanup")
        }
        .accessibilityIdentifier("agent-storage-inline-cleanup-controls")
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
                        Text(timeRange.inactiveTitle ?? L10n.text("全部聊天"))
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
                            .help(L10n.text("按主聊天及其子代理的最后活动时间筛选。空间数字是这些聊天当前仍占用的容量，不代表这段时间新增的文件。"))
                            .accessibilityLabel(L10n.text("时间范围统计说明"))
                    }
                }
                if let snapshot = model.snapshot,
                   let summary = selectedProviderSummary {
                    let diagnostics = snapshot.diagnostics(for: summary.provider)
                    if !diagnostics.isEmpty {
                        AgentStorageQualityBar(
                            presentation: AgentStorageQualityPresentation(
                                coverage: snapshot.coverage,
                                summary: summary,
                                diagnostics: diagnostics
                            ),
                            showDetails: { showQualityDetails(for: summary.provider) }
                        )
                    }
                }
                if let failure = selectedDatabaseFailures.first {
                    HStack(spacing: 8) {
                        Label(databaseFailureMessage(failure), systemImage: "cylinder.split.1x2")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer(minLength: 8)
                        if failure.status == .unsupportedFormat {
                            Button {
                                openDatabaseCompatibilityIssue(failure)
                            } label: {
                                Label(L10n.text("反馈兼容问题"), systemImage: "arrow.up.right.square")
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
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
                        Text(L10n.text("物理占用")).font(.caption)
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
                if allowsAnalysisActions, !model.isScanning {
                    Button(L10n.text("开始分析")) { model.startAnalysis() }
                        .buttonStyle(AppActionButtonStyle(kind: .primary, size: .compact))
                }
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .frame(height: 40)
        }
    }

    private func providerScanStatus(_ snapshot: AgentStorageSnapshot) -> some View {
        Group {
            if let provider = selectedProvider,
               model.reanalyzingProviders.contains(provider) {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在同步最新状态"))
                        .foregroundStyle(.secondary)
                }
            } else if let provider = selectedProvider,
                      let refreshError = model.refreshErrorsByProvider[provider] {
                HStack(spacing: 7) {
                    Label(refreshError, systemImage: "exclamationmark.triangle.fill")
                        .lineLimit(1)
                        .help(refreshError)
                    Button {
                        model.startAnalysis(provider: provider)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text("重试同步"))
                    .accessibilityLabel(L10n.text("重试同步"))
                }
                .foregroundStyle(.orange)
            } else if model.isScanning {
                AgentStorageRefreshingProgressView(model: model)
            } else if let summary = selectedProviderSummary {
                let diagnostics = snapshot.diagnostics(for: summary.provider)
                AgentStorageQualityStatusCluster(
                    presentation: AgentStorageQualityPresentation(
                        coverage: snapshot.coverage,
                        summary: summary,
                        diagnostics: diagnostics
                    ),
                    showDetails: diagnostics.isEmpty
                        ? nil
                        : { showQualityDetails(for: summary.provider) }
                )
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func globalScanStatus(_ snapshot: AgentStorageSnapshot) -> some View {
        Group {
            if model.isScanning {
                AgentStorageRefreshingProgressView(model: model)
            } else {
                AgentStorageQualityStatusCluster(
                    presentation: AgentStorageQualityPresentation(snapshot: snapshot),
                    showDetails: snapshot.diagnostics.isEmpty
                        ? nil
                        : { showQualityDetails(for: nil) }
                )
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func showQualityDetails(for provider: AgentStorageProvider?) {
        guard let snapshot = model.snapshot else { return }
        let diagnostics = provider.map(snapshot.diagnostics(for:)) ?? snapshot.diagnostics
        guard !diagnostics.isEmpty else { return }
        qualityDetails = AgentStorageQualityDetails(
            snapshot: snapshot,
            provider: provider
        )
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
                .buttonStyle(AppActionButtonStyle(kind: .primary))
            Button {
                let component = selectedDatabaseCompatibilityFailure?.diagnosticComponent
                    ?? "conversation index"
                guard let provider = selectedProvider else { return }
                NSWorkspace.shared.open(BrandLinks.agentStorageCompatibilityIssueURL(
                    provider: provider,
                    component: component
                ))
            } label: {
                Label(L10n.text("反馈兼容问题"), systemImage: "arrow.up.right.square")
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
        }
    }

    private var chatTable: some View {
        Table(visibleChatRows, selection: $selection, sortOrder: $chatSortOrder) {
            TableColumn("") { row in
                AgentStorageChatSelectionCell(
                    row: row,
                    isSelected: cleanupSelectedIDs.contains(row.familyID),
                    isPendingSynchronization: pendingCleanupSynchronizationIDs.contains(row.familyID),
                    toggleSelection: { toggleCleanupSelection(row.familyID) }
                )
            }
            .width(32)
            TableColumn(L10n.text("聊天"), value: \.title) { row in
                AgentStorageChatIdentityCell(
                    row: row,
                    isExpanded: expandedFamilies.contains(row.familyID),
                    isExpanding: expandingFamilies.contains(row.familyID),
                    toggleExpanded: { toggleExpanded(row.familyID) },
                    activate: { activateChatRow(row) }
                )
            }
            .width(min: 270, ideal: 360)
            TableColumn(L10n.text("最近活动"), value: \.updatedAt) { row in
                Text(relativeDate(row.updatedAt))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(AgentStorageChatCellActivation {
                        activateChatRow(row)
                    })
            }
            .width(min: 86, ideal: 104)
            TableColumn(L10n.text("子代理"), value: \.subagentCount) { row in
                Group {
                    if row.isFamily {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(L10n.number(row.subagentCount))
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
                    activateChatRow(row)
                })
            }
            .width(min: 76, ideal: 92)
            TableColumn(L10n.text("占用"), value: \.allocatedBytes) { row in
                VStack(alignment: .trailing, spacing: 1) {
                    Text(AgentStorageSizeFormatter.string(row.allocatedBytes))
                        .font(.body.monospacedDigit())
                    if row.databaseAttributedBytes > 0 {
                        Text(L10n.format(
                            "其中数据库 %@",
                            AgentStorageSizeFormatter.string(row.databaseAttributedBytes)
                        ))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .modifier(AgentStorageChatCellActivation {
                    activateChatRow(row)
                })
            }
            .width(min: 112, ideal: 136)
            TableColumn(L10n.text("预计立即释放")) { row in
                if row.isFamily {
                    Text(AgentStorageSizeFormatter.string(cleanupReclaimableBytes(for: row)))
                        .font(.body.weight(.medium).monospacedDigit())
                        .foregroundStyle(cleanupReclaimableBytes(for: row) > 0 ? Color.teal : Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .modifier(AgentStorageChatCellActivation {
                            activateChatRow(row)
                        })
                } else {
                    Text("-").foregroundStyle(.tertiary)
                }
            }
            .width(min: 118, ideal: 140)
            TableColumn("") { row in
                AgentStorageTableDetailButton(
                    accessibilityIdentifier: "agent-storage-chat-detail-\(row.id)",
                    action: { activateDetail(id: row.id) }
                )
            }
            .width(min: 82, ideal: 88, max: 96)
        }
        .overlay(alignment: .topLeading) {
            AgentStoragePageSelectionCheckbox(
                state: cleanupCurrentPageSelectionState,
                selectedCount: cleanupCurrentPageSelectedCount,
                totalCount: cleanupCurrentPageIDs.count,
                action: toggleCleanupCurrentPage
            )
            .padding(.leading, 16)
        }
        .overlay { tableEmptyStateIfNeeded(itemsAreEmpty: visibleChatRows.isEmpty) }
        .focused($tableHasFocus)
        .accessibilityFocused($tableAccessibilityFocus)
        .accessibilityIdentifier("agent-storage-chat-table")
        .onKeyPress(.return) {
            showSelectedDetail()
            return .handled
        }
        .onKeyPress(.space) {
            guard let selection,
                  let row = visibleChatRows.first(where: { $0.id == selection }),
                  row.isFamily else { return .ignored }
            toggleCleanupSelection(row.familyID)
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
            }
            .buttonStyle(AppIconButtonStyle(size: 28, isFramed: false))
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
            }
            .buttonStyle(AppIconButtonStyle(size: 28, isFramed: false))
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
                Text(L10n.number(item.artifactCount)).monospacedDigit()
            }
            .width(min: 64, ideal: 80)
            TableColumn(L10n.text("最近变化")) { item in
                Text(item.updatedAt.map(relativeDate) ?? "-")
                    .foregroundStyle(.secondary)
            }
            .width(min: 86, ideal: 104)
            TableColumn(L10n.text("占用"), value: \.allocatedBytes) { item in
                VStack(alignment: .trailing, spacing: 1) {
                    Text(AgentStorageSizeFormatter.string(item.allocatedBytes))
                        .font(.body.monospacedDigit())
                    if item.databaseAttributedBytes > 0 {
                        Text(L10n.format(
                            "已归属聊天 %@",
                            AgentStorageSizeFormatter.string(item.databaseAttributedBytes)
                        ))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 112, ideal: 136)
            TableColumn("") { item in
                AgentStorageTableDetailButton(
                    accessibilityIdentifier: "agent-storage-global-detail-\(item.id)",
                    action: { activateDetail(id: item.id) }
                )
            }
            .width(min: 82, ideal: 88, max: 96)
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
                Text(L10n.number(item.artifactCount)).monospacedDigit()
            }
            .width(min: 64, ideal: 80)
            TableColumn(L10n.text("占用"), value: \.allocatedBytes) { item in
                Text(AgentStorageSizeFormatter.string(item.allocatedBytes))
                    .font(.body.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 92, ideal: 112)
            TableColumn("") { item in
                AgentStorageTableDetailButton(
                    accessibilityIdentifier: "agent-storage-unattributed-detail-\(item.id)",
                    action: { activateDetail(id: item.id) }
                )
            }
            .width(min: 82, ideal: 88, max: 96)
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
                            .buttonStyle(AppActionButtonStyle(kind: .secondary))
                    }
                } else if let inactiveTitle = timeRange.inactiveTitle,
                          archiveFilter == .all, selectedProject == nil {
                    ContentUnavailableView {
                        Label(
                            L10n.format("没有%@的聊天", inactiveTitle),
                            systemImage: "clock"
                        )
                    } description: {
                        Text(L10n.text("可缩短未活动时间，或返回查看全部聊天。"))
                    } actions: {
                        Button(L10n.text("查看全部聊天")) { timeRange = .all }
                            .buttonStyle(AppActionButtonStyle(kind: .secondary))
                    }
                } else if hasActiveFilter {
                    ContentUnavailableView {
                        Label(L10n.text("没有符合筛选条件的聊天"), systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text(L10n.text("调整或清除筛选后再试。"))
                    } actions: {
                        Button(L10n.text("清除筛选"), action: clearFilters)
                            .buttonStyle(AppActionButtonStyle(kind: .secondary))
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
                            .buttonStyle(AppActionButtonStyle(kind: .secondary))
                    }
                } else if hasActiveFilter {
                    ContentUnavailableView {
                        Label(L10n.text("没有符合筛选条件的全局数据"), systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text(L10n.text("调整或清除筛选后再试。"))
                    } actions: {
                        Button(L10n.text("清除筛选"), action: clearFilters)
                            .buttonStyle(AppActionButtonStyle(kind: .secondary))
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
                            .buttonStyle(AppActionButtonStyle(kind: .secondary))
                    }
                } else if hasActiveFilter {
                    ContentUnavailableView {
                        Label(L10n.text("没有符合筛选条件的未归属数据"), systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text(L10n.text("调整或清除筛选后再试。"))
                    } actions: {
                        Button(L10n.text("清除筛选"), action: clearFilters)
                            .buttonStyle(AppActionButtonStyle(kind: .secondary))
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
            AgentStorageOverviewSkeleton(
                progress: model.progress,
                progressByProvider: model.progressByProvider,
                startedAt: model.scanStartedAt
            )
        case .stopped:
            ContentUnavailableView {
                Label(L10n.text("扫描已停止"), systemImage: "pause.circle")
            } description: {
                Text(allowsAnalysisActions
                    ? L10n.text("尚未生成可显示的结果")
                    : L10n.text("返回空间地图重新开始整体分析。"))
            } actions: {
                if allowsAnalysisActions {
                    Button(L10n.text("重新分析")) { model.startAnalysis() }
                        .buttonStyle(AppActionButtonStyle(kind: .primary))
                }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label(L10n.text("无法完成 AI 空间分析"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                if allowsAnalysisActions {
                    Button(L10n.text("重试")) { model.startAnalysis() }
                        .buttonStyle(AppActionButtonStyle(kind: .primary))
                }
            }
        case .idle where model.requiresAnalysis:
            if allowsAnalysisActions {
                AgentStorageAnalysisInvitation(start: model.startAnalysis)
            } else {
                ContentUnavailableView {
                    Label(L10n.text("等待空间地图整体分析"), systemImage: "chart.bar.xaxis")
                } description: {
                    Text(L10n.text("Codex 与 Claude 深度分析由空间地图的统一分析任务生成。"))
                }
            }
        default:
            ContentUnavailableView {
                Label(L10n.text("尚未分析 AI Agent 空间"), systemImage: "sparkles")
            } description: {
                Text(L10n.text("分析 Codex、Claude 和 OpenCode 的聊天、子代理与全局运行时"))
            } actions: {
                if allowsAnalysisActions {
                    Button(L10n.text("开始分析")) { model.startAnalysis() }
                        .buttonStyle(AppActionButtonStyle(kind: .primary))
                }
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
            unattributedSortRules: unattributedSortRules,
            usesMockTitles: usesMockTitles
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

    private var selectedProviderSources: [AgentStorageSource] {
        guard let selectedProvider else { return [] }
        return (model.snapshot?.sources ?? [])
            .filter { $0.provider == selectedProvider }
            .sorted {
                if $0.allocatedBytes != $1.allocatedBytes {
                    return $0.allocatedBytes > $1.allocatedBytes
                }
                return $0.resolvedPath.localizedStandardCompare($1.resolvedPath) == .orderedAscending
            }
    }

    private var selectedDatabaseAttributions: [AgentStorageDatabaseAttributionSummary] {
        guard let provider = selectedProvider else { return [] }
        return model.snapshot?.databaseAttributions.filter { $0.provider == provider } ?? []
    }

    private var selectedDatabaseFailures: [AgentStorageDatabaseAttributionSummary] {
        selectedDatabaseAttributions.filter { $0.status != .completed }
    }

    private var selectedDatabaseCompatibilityFailure: AgentStorageDatabaseAttributionSummary? {
        selectedDatabaseFailures.first { $0.status == .unsupportedFormat }
    }

    private func databaseFailureMessage(
        _ failure: AgentStorageDatabaseAttributionSummary
    ) -> String {
        switch failure.status {
        case .unsupportedFormat:
            return L10n.text("数据库格式暂未适配；物理占用已统计，部分记录暂未归属到聊天。")
        case .temporarilyBusy:
            return L10n.text("数据库正在被 Agent 使用；物理占用已统计，可稍后刷新以补充聊天归属。")
        case .unsupportedJournalMode:
            return L10n.text("数据库当前写入模式无法安全读取；物理占用已统计，聊天归属已跳过。")
        case .ambiguousOwnership:
            return L10n.text("发现重复或共享的数据库文件；为避免重复计数，聊天归属已跳过。")
        case .unavailable, .unreadable:
            return L10n.text("数据库记录暂时无法读取；物理占用已统计，聊天归属可能不完整。")
        case .completed:
            return L10n.text("数据库记录已归属到聊天。")
        }
    }

    private func openDatabaseCompatibilityIssue(
        _ failure: AgentStorageDatabaseAttributionSummary
    ) {
        guard failure.status == .unsupportedFormat else { return }
        NSWorkspace.shared.open(BrandLinks.agentStorageCompatibilityIssueURL(
            provider: failure.provider,
            component: failure.diagnosticComponent ?? "conversation database"
        ))
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

    private func scheduleSnapshotIndex(_ snapshot: AgentStorageSnapshot?) {
        indexTask?.cancel()
        indexGeneration &+= 1
        let requestedGeneration = indexGeneration

        guard let snapshot else {
            providerOverviewItems = []
            familyIndex = [:]
            detailIndex = [:]
            cleanupBytesByFamilyID = [:]
            availableProjectsCache = []
            chatPageIndex = 0
            chatPagination = .empty
            expandingFamilies = []
            isProjecting = false
            return
        }
        let requestedProvider = selectedProvider
        if requestedProvider != nil { isProjecting = true }
        indexTask = Task { @MainActor in
            await Task.yield()
            let worker = Task.detached(priority: .userInitiated) {
                AgentStorageIndexBuilder.build(
                    snapshot: snapshot,
                    provider: requestedProvider
                )
            }
            let index = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  indexGeneration == requestedGeneration,
                  selectedProvider == requestedProvider else { return }
            providerOverviewItems = index.providerOverviewItems
            guard let requestedProvider else {
                familyIndex = [:]
                detailIndex = [:]
                cleanupBytesByFamilyID = [:]
                isProjecting = false
                indexTask = nil
                return
            }
            guard snapshot.providers.contains(where: { $0.provider == requestedProvider }),
                  let dataset = index.dataset else {
                indexTask = nil
                leaveProvider()
                return
            }
            familyIndex = index.familyIndex
            detailIndex = index.detailIndex
            cleanupBytesByFamilyID = index.cleanupBytesByFamilyID
            expandingFamilies.formIntersection(Set(index.familyIndex.keys))
            reconcileWorkspaceState(with: dataset)
            indexTask = nil
            scheduleProjection()
        }
    }

    private func enterProvider(_ provider: AgentStorageProvider) {
        guard model.snapshot?.providers.first(where: { $0.provider == provider })?
            .supportStatus != .notInstalled else { return }
        isRestoringWorkspace = true
        resetCleanupSelection()
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
        familyIndex = [:]
        detailIndex = [:]
        cleanupBytesByFamilyID = [:]
        visibleChatRows = []
        visibleGlobalItems = []
        visibleUnattributedItems = []
        isProjecting = true
        scheduleSnapshotIndex(model.snapshot)
        Task { @MainActor in
            await Task.yield()
            isRestoringWorkspace = false
            tableHasFocus = true
            tableAccessibilityFocus = true
        }
    }

    private func leaveProvider() {
        resetCleanupSelection()
        projectionTask?.cancel()
        projectionGeneration &+= 1
        indexTask?.cancel()
        indexGeneration &+= 1
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
        showsTimeRangePopover = false
        selection = nil
        showsTransientDetail = false
        compactDetail = nil
        visibleChatRows = []
        visibleGlobalItems = []
        visibleUnattributedItems = []
        familyIndex = [:]
        detailIndex = [:]
        cleanupBytesByFamilyID = [:]
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

    private func handleCleanupCompletion(_ result: AgentStorageCleanupResult) {
        let succeededTargets = result.targets.filter { $0.outcome == .succeeded }
        let succeededIDs = Set(succeededTargets.map(\.id))
        cleanupSelectedIDs.subtract(succeededIDs)
        for target in succeededTargets {
            pendingCleanupSynchronizationIDsByProvider[target.family.provider, default: []]
                .insert(target.id)
        }
        let providers = result.providersRequiringRefresh
        guard !providers.isEmpty else { return }
        cleanupDidAffectProviders?(providers)
        model.refreshAfterCleanup(providers: providers)
    }

    private func reconcileWorkspaceState(with dataset: AgentStorageProviderDataset) {
        let validFamilies = Set(dataset.families.map(\.id))
        expandedFamilies.formIntersection(validFamilies)
        cleanupSelectedIDs.formIntersection(validFamilies)
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
        } else if let providerExitAction {
            providerExitAction()
        } else {
            leaveProvider()
        }
    }

    private func resolvedDetail(id: String) -> AgentStorageResolvedDetail? {
        detailIndex[id]
    }

    private func activateChatRow(_ row: AgentStorageChatRow) {
        activateDetail(id: row.id)
    }

    private var cleanupSelectedFamilies: [AgentStorageThreadFamily] {
        cleanupSelectedIDs.sorted().compactMap { familyIndex[$0] }
    }

    private var pendingCleanupSynchronizationIDs: Set<String> {
        guard let selectedProvider else { return [] }
        return pendingCleanupSynchronizationIDsByProvider[selectedProvider, default: []]
    }

    private var cleanupCurrentPageIDs: Set<String> {
        Set(visibleChatRows.lazy.filter(\.isFamily).map(\.familyID))
            .subtracting(pendingCleanupSynchronizationIDs)
    }

    private var cleanupCurrentPageIsSelected: Bool {
        !cleanupCurrentPageIDs.isEmpty
            && cleanupCurrentPageIDs.isSubset(of: cleanupSelectedIDs)
    }

    private var cleanupCurrentPageSelectionState: AgentStorageBatchSelectionEngine.PageSelectionState {
        AgentStorageBatchSelectionEngine.pageSelectionState(
            selectedIDs: cleanupSelectedIDs,
            pageFamilyIDs: cleanupCurrentPageIDs
        )
    }

    private var cleanupCurrentPageSelectedCount: Int {
        cleanupCurrentPageIDs.intersection(cleanupSelectedIDs).count
    }

    private var cleanupAllMatchingIDs: Set<String> {
        Set(visibleChatSummary.families.map(\.id))
            .subtracting(pendingCleanupSynchronizationIDs)
    }

    private var cleanupAllMatchingAreSelected: Bool {
        !cleanupAllMatchingIDs.isEmpty
            && cleanupAllMatchingIDs.isSubset(of: cleanupSelectedIDs)
    }

    private func resetCleanupSelection() {
        cleanupReviewTask?.cancel()
        cleanupReviewGeneration &+= 1
        cleanupSelectedIDs = []
        cleanupReview = nil
        isCleanupReviewUpdating = false
        cleanupSession = nil
    }

    private func toggleCleanupSelection(_ id: String) {
        guard !pendingCleanupSynchronizationIDs.contains(id) else { return }
        if cleanupSelectedIDs.contains(id) {
            cleanupSelectedIDs.remove(id)
        } else {
            cleanupSelectedIDs.insert(id)
        }
    }

    private func toggleCleanupCurrentPage() {
        cleanupSelectedIDs = AgentStorageBatchSelectionEngine.togglingCurrentPage(
            selectedIDs: cleanupSelectedIDs,
            pageFamilyIDs: cleanupCurrentPageIDs
        )
    }

    private func toggleCleanupAllMatching() {
        if cleanupAllMatchingAreSelected {
            cleanupSelectedIDs.subtract(cleanupAllMatchingIDs)
        } else {
            cleanupSelectedIDs.formUnion(cleanupAllMatchingIDs)
        }
    }

    private func scheduleCleanupReview() {
        cleanupReviewTask?.cancel()
        cleanupReviewGeneration &+= 1
        let requestedGeneration = cleanupReviewGeneration
        let families = cleanupSelectedFamilies
        guard !families.isEmpty else {
            cleanupReview = nil
            isCleanupReviewUpdating = false
            return
        }
        isCleanupReviewUpdating = true
        cleanupReviewTask = Task { @MainActor in
            await Task.yield()
            let worker = Task.detached(priority: .userInitiated) {
                AgentStorageCleanupReview(families: families)
            }
            let review = await worker.value
            guard !Task.isCancelled,
                  cleanupReviewGeneration == requestedGeneration else { return }
            cleanupReview = review
            isCleanupReviewUpdating = false
            cleanupReviewTask = nil
        }
    }

    private func presentCleanupReview() {
        guard let cleanupReview, !isCleanupReviewUpdating else { return }
        cleanupSession = AgentStorageCleanupSession(review: cleanupReview)
    }

    private func hasRemainingCleanupItems(
        after session: AgentStorageCleanupSession
    ) -> Bool {
        let reviewedIDs = Set(session.review.families.map(\.id))
        return !cleanupAllMatchingIDs.subtracting(reviewedIDs).isEmpty
    }

    private func cleanupReclaimableBytes(for row: AgentStorageChatRow) -> UInt64 {
        guard row.isFamily else { return 0 }
        return cleanupBytesByFamilyID[row.familyID] ?? 0
    }

    private func relativeDate(_ date: Date) -> String {
        L10n.relativeDate(date, abbreviated: true)
    }
}

private struct AgentStorageInlineCleanupInspector: View {
    @AppStorage(AgentStoragePreferences.mockTitlesKey) private var usesMockTitles = false
    let provider: AgentStorageProvider?
    let selectedFamilies: [AgentStorageThreadFamily]
    let review: AgentStorageCleanupReview?
    let isUpdating: Bool
    let cancel: () -> Void
    let continueToReview: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            inspectorHeader
            Divider()
            metrics
            Divider()
            breakdown
            Divider()
            selectedList
            Divider()
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("agent-storage-inline-cleanup-inspector")
    }

    private var inspectorHeader: some View {
        HStack(spacing: 12) {
            if let provider {
                AgentStorageProviderIcon(provider: provider, size: 30)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("清理计划"))
                    .font(.headline)
                Text(L10n.text("直接勾选左侧聊天，无需再次选择"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 18)
        .frame(height: 72)
    }

    private var metrics: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                cleanupMetric(
                    L10n.text("已选聊天"),
                    L10n.number(selectedFamilies.count),
                    symbol: "checkmark.circle.fill"
                )
                Divider().frame(height: 44)
                cleanupMetric(
                    L10n.text("预计立即释放"),
                    isUpdating ? "—" : AgentStorageSizeFormatter.string(review?.reclaimableBytes ?? 0),
                    symbol: "arrow.down.to.line.compact"
                )
            }
            Divider().padding(.horizontal, 14)
            HStack(spacing: 0) {
                cleanupMetric(
                    L10n.text("已测量"),
                    isUpdating ? "—" : AgentStorageSizeFormatter.string(review?.totalBytes ?? 0),
                    symbol: "internaldrive"
                )
                Divider().frame(height: 44)
                cleanupMetric(
                    L10n.text("保留在磁盘"),
                    isUpdating ? "—" : AgentStorageSizeFormatter.string(review?.retainedBytes ?? 0),
                    symbol: "lock.shield"
                )
            }
        }
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.38))
    }

    private func cleanupMetric(_ title: String, _ value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var breakdown: some View {
        if let review, !review.artifacts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("可验证文件构成"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(cleanupCategoryBreakdown(review), id: \.category) { item in
                    HStack(spacing: 8) {
                        Circle().fill(cleanupCategoryColor(item.category)).frame(width: 7, height: 7)
                        Text(cleanupCategoryTitle(item.category)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(AgentStorageSizeFormatter.string(item.bytes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        } else {
            HStack(spacing: 9) {
                if isUpdating { ProgressView().controlSize(.small) }
                Image(systemName: "doc.badge.ellipsis")
                    .foregroundStyle(.secondary)
                Text(L10n.text("选择后计算可由官方方式验证的文件"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48, alignment: .leading)
        }
    }

    private func cleanupCategoryBreakdown(
        _ review: AgentStorageCleanupReview
    ) -> [(category: AgentStorageArtifactCategory, bytes: UInt64)] {
        var bytesByCategory: [AgentStorageArtifactCategory: UInt64] = [:]
        for artifact in review.artifacts {
            let category = artifact.category ?? .other
            let current = bytesByCategory[category, default: 0]
            let sum = current.addingReportingOverflow(artifact.allocatedBytes)
            bytesByCategory[category] = sum.overflow ? .max : sum.partialValue
        }
        return bytesByCategory.map { (category: $0.key, bytes: $0.value) }.sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.category.rawValue < $1.category.rawValue
        }
    }

    private func cleanupCategoryTitle(_ category: AgentStorageArtifactCategory) -> String {
        switch category {
        case .conversation: L10n.text("会话文件")
        case .toolResult: L10n.text("工具结果")
        case .subagent: L10n.text("子代理文件")
        case .fileHistory: L10n.text("文件历史")
        case .attachment: L10n.text("附件")
        case .snapshot: L10n.text("快照")
        case .task: L10n.text("任务")
        case .workflow: L10n.text("工作流")
        case .other: L10n.text("其它文件")
        }
    }

    private func cleanupCategoryColor(_ category: AgentStorageArtifactCategory) -> Color {
        switch category {
        case .conversation, .subagent: .teal
        case .toolResult, .task, .workflow: .blue
        case .fileHistory, .snapshot: .orange
        case .attachment: .purple
        case .other: .secondary
        }
    }

    @ViewBuilder
    private var selectedList: some View {
        if selectedFamilies.isEmpty {
            ContentUnavailableView {
                Label(L10n.text("选择要清理的聊天"), systemImage: "checkmark.square")
            } description: {
                Text(L10n.text("勾选后，这里会实时汇总可验证文件与预计释放空间。"))
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(selectedFamilies) { family in
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(usesMockTitles
                                    ? AgentStorageMockTitleCatalog.title(
                                        provider: family.provider,
                                        nativeID: family.nativeThreadID,
                                        isSubagent: false
                                    )
                                    : family.title
                                ).font(.callout.weight(.medium)).lineLimit(1)
                                Text(family.project).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text(AgentStorageSizeFormatter.string(family.attributedBytes))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 52)
                        Divider().padding(.leading, 46)
                    }
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                L10n.text("最终提交前会再次核验活动状态和官方清理能力。"),
                systemImage: "checkmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.text("退出选择"), action: cancel)
                    .buttonStyle(AppActionButtonStyle(kind: .secondary))
                Spacer()
                if isUpdating { ProgressView().controlSize(.small) }
                Button(L10n.text("检查并清理"), systemImage: "arrow.right", action: continueToReview)
                    .buttonStyle(AppActionButtonStyle(kind: .primary))
                    .disabled(review == nil || isUpdating)
            }
        }
        .padding(16)
    }
}

private struct ClaudeNodeRuntimeBar: View {
    let model: ClaudeNodeRuntimeStatusModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.and.arrow.down.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 32, height: 32)
                .background(statusColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("Node.js 运行时"))
                    .font(.caption.weight(.semibold))
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(statusText)
            }

            Spacer(minLength: 12)
            action
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.24))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("claude-node-runtime")
    }

    @ViewBuilder
    private var action: some View {
        switch model.phase {
        case .checking:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(L10n.text("检测中…"))
        case .available:
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help(L10n.text("重新检测"))
            .accessibilityLabel(L10n.text("重新检测"))
        case .missing, .failed:
            Button {
                model.download()
            } label: {
                Label(
                    L10n.format("下载 Node.js v%@", ClaudeNodeRuntime.pinnedVersion),
                    systemImage: "arrow.down.circle"
                )
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary, size: .compact))
        case .downloading, .verifying, .installing:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(provisioningActionTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .checking: .secondary
        case .available: .green
        case .missing: .orange
        case .downloading, .verifying, .installing: .accentColor
        case .failed: .red
        }
    }

    private var statusText: String {
        switch model.phase {
        case .checking:
            return L10n.text("检测中…")
        case .available(let availability):
            let status = [availability.version, availability.source.localizedLabel]
                .compactMap { $0 }
                .joined(separator: " · ")
            return "\(status) · \(abbreviatedPath(availability.path))"
        case .missing:
            return L10n.text("未检测到可用运行时")
        case .downloading:
            return L10n.text("正在下载官方运行时…")
        case .verifying:
            return L10n.text("正在校验运行时…")
        case .installing:
            return L10n.text("正在安装运行时…")
        case .failed(let message):
            return message
        }
    }

    private var provisioningActionTitle: String {
        switch model.phase {
        case .downloading: L10n.text("正在下载")
        case .verifying: L10n.text("正在校验")
        case .installing: L10n.text("正在安装")
        default: ""
        }
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + String(path.dropFirst(home.count))
    }
}

private struct AgentStorageAgeFilterPopover: View {
    @Binding var range: AgentStorageTimeRange
    let scannedAt: Date
    let summary: AgentStorageChatRangeProjection
    let isUpdating: Bool

    @Environment(\.dismiss) private var dismiss

    private let presetDays = [1, 7, 30, 90]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Picker(L10n.text("聊天范围"), selection: showsInactiveOnly) {
                Text(L10n.text("全部聊天")).tag(false)
                Text(L10n.text("旧聊天")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(L10n.text("聊天范围"))

            if range != .all {
                inactivityControls
                cutoffSummary
            } else {
                allChatsSummary
            }

            HStack {
                if isUpdating {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.text("正在更新统计"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button(L10n.text("完成")) { dismiss() }
                    .buttonStyle(AppActionButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 400)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-storage-age-filter-popover")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("按未活动时间筛选"))
                    .font(.headline)
                Text(L10n.text("按主聊天及其子代理的最后活动时间设置门槛。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var inactivityControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.text("常用门槛"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker(L10n.text("常用门槛"), selection: presetSelection) {
                    ForEach(presetDays, id: \.self) { days in
                        Text(shortDayLabel(days)).tag(days)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(L10n.text("常用门槛"))
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.text("自定义门槛"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(range.inactiveTitle ?? AgentStorageTimeRange.thirtyDays.inactiveTitle ?? "")
                        .font(.callout.weight(.semibold).monospacedDigit())
                }

                Slider(value: logarithmicSliderValue, in: 0...1)
                    .accessibilityLabel(L10n.text("未活动时间门槛"))
                    .accessibilityValue(range.inactiveTitle ?? "")
                    .accessibilityIdentifier("agent-storage-age-slider")

                HStack {
                    Text(L10n.text("1 天"))
                    Spacer()
                    Text(L10n.text("365 天"))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)

                Stepper(value: inactiveDays, in: AgentStorageTimeRange.minimumInactiveDays...AgentStorageTimeRange.maximumInactiveDays) {
                    Text(L10n.format("精确调整：%d 天", effectiveInactiveDays))
                        .font(.caption)
                }
                .accessibilityIdentifier("agent-storage-age-stepper")
            }
        }
    }

    private var cutoffSummary: some View {
        HStack(spacing: 0) {
            ageMetric(
                title: L10n.text("截止日期"),
                value: cutoffDate.map {
                    L10n.date($0, date: .abbreviated, time: .omitted)
                } ?? L10n.text("未知")
            )
            ageMetric(
                title: L10n.text("符合条件"),
                value: L10n.format("%d 个主聊天", currentSummary.mainThreadCount)
            )
            ageMetric(
                title: L10n.text("当前占用"),
                value: AgentStorageSizeFormatter.string(currentSummary.chatBytes)
            )
        }
        .padding(.vertical, 12)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.62),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var allChatsSummary: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("正在显示全部聊天"))
                    .font(.callout.weight(.semibold))
                Text(L10n.text("进入批量清理时会自动保护最近 30 天仍有活动的聊天。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.5),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func ageMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
    }

    private var showsInactiveOnly: Binding<Bool> {
        Binding(
            get: { range != .all },
            set: { range = $0 ? .thirtyDays : .all }
        )
    }

    private var presetSelection: Binding<Int> {
        Binding(
            get: { effectiveInactiveDays },
            set: { range = .olderThan(days: $0) }
        )
    }

    private var inactiveDays: Binding<Int> {
        Binding(
            get: { effectiveInactiveDays },
            set: { range = .olderThan(days: $0) }
        )
    }

    private var logarithmicSliderValue: Binding<Double> {
        Binding(
            get: {
                log(Double(effectiveInactiveDays))
                    / log(Double(AgentStorageTimeRange.maximumInactiveDays))
            },
            set: { position in
                let maximum = Double(AgentStorageTimeRange.maximumInactiveDays)
                let days = Int(pow(maximum, position).rounded())
                range = .olderThan(days: days)
            }
        )
    }

    private var effectiveInactiveDays: Int {
        range.inactiveDays ?? AgentStorageTimeRange.thirtyDays.inactiveDays ?? 30
    }

    private var cutoffDate: Date? {
        AgentStorageTimeRange.olderThan(days: effectiveInactiveDays).cutoffDate(relativeTo: scannedAt)
    }

    private var currentSummary: AgentStorageChatRangeProjection {
        AgentStorageChatRangeProjection(families: summary.families.filter {
            range.includes(updatedAt: $0.updatedAt, relativeTo: scannedAt)
        })
    }

    private func shortDayLabel(_ days: Int) -> String {
        switch days {
        case 30: L10n.text("1 个月")
        case 90: L10n.text("3 个月")
        default: L10n.format("%d 天", days)
        }
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

    private var isInstalled: Bool { item.summary.supportStatus != .notInstalled }

    @ViewBuilder
    var body: some View {
        if isInstalled {
            Button(action: open) { cardContent }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.14), value: isHovering)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilitySummary)
                .accessibilityAddTraits(.isButton)
        } else {
            cardContent
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilitySummary)
        }
    }

    private var cardContent: some View {
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
                    if isInstalled {
                        Image(systemName: "chevron.right")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(isHovering ? brandColor : Color.secondary)
                            .frame(width: 30, height: 30)
                            .background(.quaternary, in: Circle())
                    } else {
                        Label(L10n.text("未安装"), systemImage: "minus.circle")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("独占占用"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(isInstalled
                            ? AgentStorageSizeFormatter.string(item.exclusiveBytes)
                            : L10n.text("未发现数据"))
                            .font(.system(size: 30, weight: .semibold))
                            .monospacedDigit()
                        if isInstalled {
                            Text(item.shareOfTotal, format: .percent.precision(.fractionLength(1)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if isInstalled {
                    VStack(spacing: 10) {
                        AgentStorageCompositionBar(item: item, chatColor: brandColor)
                        metrics
                    }
                } else {
                    Text(L10n.text("未发现 CLI 或 Desktop 数据位置。安装后重新扫描即可开始统计。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                }

                Divider()
                HStack(spacing: 16) {
                    if item.summary.supportStatus == .notInstalled {
                        Label(L10n.text("不影响其他 Agent 的分析"), systemImage: "checkmark.shield")
                    } else if item.summary.supportStatus == .unsupportedFormat {
                        Label(L10n.text("聊天索引待适配"), systemImage: "exclamationmark.triangle")
                    } else {
                        Label(
                            "\(L10n.number(item.summary.threadCount)) \(L10n.text("个主聊天"))",
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
            isHovering && isInstalled
                ? Color(nsColor: .controlBackgroundColor).opacity(0.9)
                : Color(nsColor: .controlBackgroundColor).opacity(isInstalled ? 0.56 : 0.34),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isHovering && isInstalled
                        ? brandColor.opacity(0.48)
                        : Color(nsColor: .separatorColor).opacity(0.72),
                    lineWidth: 1
                )
        }
        .visualEffectShadow(
            color: .black.opacity(isHovering && isInstalled ? 0.08 : 0.035),
            radius: isHovering && isInstalled ? 10 : 4,
            y: 2
        )
    }

    private var brandColor: Color {
        switch item.provider {
        case .codex: Color(red: 0.08, green: 0.55, blue: 0.43)
        case .claude: Color(red: 0.82, green: 0.39, blue: 0.18)
        case .openCode: Color(red: 0.30, green: 0.42, blue: 0.82)
        }
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
        case .notInstalled:
            return L10n.text("未安装或未发现数据")
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
        case .notInstalled:
            return L10n.text("未发现 Codex、Claude 或 OpenCode 的 CLI/Desktop 数据目录；其他已安装 Agent 仍可正常分析。")
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

private struct AgentStorageFilterPopover: View {
    @Environment(\.dismiss) private var dismiss
    let scope: AgentStorageScope
    @Binding var archiveFilter: AgentStorageArchiveFilter
    @Binding var selectedProject: String?
    @Binding var selectedGlobalCategory: AgentStorageGlobalCategory?
    @Binding var selectedUnattributedReason: AgentStorageUnattributedReason?
    let projects: [String]
    let hidesPrivateDetails: Bool
    let resultCount: Int
    let isUpdating: Bool
    let clear: () -> Void
    @State private var projectQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    filterControls
                }
                .padding(16)
            }
            .scrollIndicators(.automatic)
            Divider()
            footer
        }
        .frame(width: 360)
        .frame(maxHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { dismiss() }
        .accessibilityIdentifier("agent-storage-filter-popover")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text("筛选"))
                    .font(.headline)
                Text(filterContextTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            Button(L10n.text("清除筛选"), action: clear)
                .buttonStyle(.plain)
                .foregroundStyle(hasActiveScopeFilter ? Color.accentColor : Color.secondary)
                .disabled(!hasActiveScopeFilter)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(AppIconButtonStyle(size: 28, isFramed: false))
            .help(L10n.text("关闭筛选"))
            .accessibilityLabel(L10n.text("关闭筛选"))
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    @ViewBuilder
    private var filterControls: some View {
        switch scope {
        case .chats:
            VStack(alignment: .leading, spacing: 9) {
                filterSectionTitle("聊天状态")
                Picker(L10n.text("聊天状态"), selection: $archiveFilter) {
                    ForEach(AgentStorageArchiveFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(L10n.text("聊天状态"))
            }

            if !hidesPrivateDetails, !projects.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        filterSectionTitle("项目")
                        Spacer()
                        if selectedProject != nil {
                            Text(L10n.text("已选择 1 项"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if repositoryProjects.count > 7 {
                        projectSearchField
                    }
                    projectChoices
                }
            }
        case .global:
            VStack(alignment: .leading, spacing: 9) {
                filterSectionTitle("类别")
                filterChoice(
                    title: L10n.text("全部类别"),
                    symbol: "square.grid.2x2",
                    isSelected: selectedGlobalCategory == nil
                ) { selectedGlobalCategory = nil }
                ForEach(AgentStorageGlobalCategory.allCases, id: \.self) { category in
                    filterChoice(
                        title: category.localizedTitle,
                        symbol: "shippingbox",
                        isSelected: selectedGlobalCategory == category
                    ) { selectedGlobalCategory = category }
                }
            }
        case .unattributed:
            VStack(alignment: .leading, spacing: 9) {
                filterSectionTitle("原因")
                filterChoice(
                    title: L10n.text("全部原因"),
                    symbol: "questionmark.folder",
                    isSelected: selectedUnattributedReason == nil
                ) { selectedUnattributedReason = nil }
                ForEach(AgentStorageUnattributedReason.allCases, id: \.self) { reason in
                    filterChoice(
                        title: reason.localizedTitle,
                        symbol: "exclamationmark.circle",
                        isSelected: selectedUnattributedReason == reason
                    ) { selectedUnattributedReason = reason }
                }
            }
        }
    }

    private var projectSearchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L10n.text("搜索项目"), text: $projectQuery)
                .textFieldStyle(.plain)
            if !projectQuery.isEmpty {
                Button {
                    projectQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.text("清空搜索"))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var projectChoices: some View {
        filterChoice(
            title: L10n.text("全部项目"),
            symbol: "folder",
            isSelected: selectedProject == nil
        ) { selectedProject = nil }

        if filteredRepositoryProjects.isEmpty, !projectQuery.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                Text(L10n.text("没有匹配的项目"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 48)
        } else {
            VStack(spacing: 2) {
                ForEach(filteredRepositoryProjects, id: \.self) { project in
                    filterChoice(
                        title: localizedAgentStorageProjectName(project),
                        symbol: "folder",
                        isSelected: selectedProject == project
                    ) { selectedProject = project }
                }
            }
        }

        if includesNonProjectDirectory, projectQuery.isEmpty {
            Divider().padding(.vertical, 2)
            filterChoice(
                title: localizedAgentStorageProjectName(agentStorageNonProjectDirectoryName),
                symbol: "folder.badge.questionmark",
                isSelected: selectedProject == agentStorageNonProjectDirectoryName
            ) { selectedProject = agentStorageNonProjectDirectoryName }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if isUpdating {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.text("正在更新筛选结果"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label(
                    L10n.format("%d 个结果", resultCount),
                    systemImage: "checkmark.circle"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.text("完成")) { dismiss() }
                .buttonStyle(AppActionButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private func filterSectionTitle(_ title: String) -> some View {
        Text(L10n.text(title))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func filterChoice(
        title: String,
        symbol: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.11) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var repositoryProjects: [String] {
        projects.filter { $0 != agentStorageNonProjectDirectoryName }
    }

    private var filteredRepositoryProjects: [String] {
        let query = projectQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return repositoryProjects }
        return repositoryProjects.filter {
            $0.localizedCaseInsensitiveContains(query)
        }
    }

    private var includesNonProjectDirectory: Bool {
        projects.contains(agentStorageNonProjectDirectoryName)
    }

    private var hasActiveScopeFilter: Bool {
        switch scope {
        case .chats: archiveFilter != .all || selectedProject != nil
        case .global: selectedGlobalCategory != nil
        case .unattributed: selectedUnattributedReason != nil
        }
    }

    private var filterContextTitle: String {
        switch scope {
        case .chats: L10n.text("聊天")
        case .global: L10n.text("全局")
        case .unattributed: L10n.text("未归属")
        }
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
    let refresh: (() -> Void)?
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
    let databaseAttributedBytes: UInt64
    let isFamily: Bool
    let depth: Int

    init(
        family: AgentStorageThreadFamily,
        hidesPrivateDetails: Bool,
        usesMockTitles: Bool = false
    ) {
        id = family.id
        nativeID = family.nativeThreadID
        parentID = nil
        familyID = family.id
        provider = family.provider
        title = usesMockTitles
            ? AgentStorageMockTitleCatalog.title(
                provider: family.provider,
                nativeID: family.nativeThreadID,
                isSubagent: false
            )
            : hidesPrivateDetails
            ? "\(family.provider.displayName) \(L10n.text("聊天")) · \(L10n.date(family.updatedAt, date: .abbreviated, time: .omitted))"
            : family.title
        project = hidesPrivateDetails
            ? L10n.text("已隐藏项目")
            : localizedAgentStorageProjectName(family.project)
        updatedAt = family.updatedAt
        subagentCount = family.subagentCount
        let subagentTotal = family.subagentAllocatedBytes.addingReportingOverflow(
            family.subagentDatabaseAttributedBytes
        )
        subagentAllocatedBytes = subagentTotal.overflow ? .max : subagentTotal.partialValue
        allocatedBytes = family.attributedBytes
        databaseAttributedBytes = family.databaseAttributedBytes
        isFamily = true
        depth = 0
    }

    init(
        node: AgentStorageThreadNode,
        family: AgentStorageThreadFamily,
        parentRowID: String,
        hidesPrivateDetails: Bool,
        usesMockTitles: Bool = false
    ) {
        id = node.id
        nativeID = node.nativeID
        parentID = parentRowID
        familyID = family.id
        provider = family.provider
        title = usesMockTitles
            ? AgentStorageMockTitleCatalog.title(
                provider: family.provider,
                nativeID: node.nativeID,
                isSubagent: true
            )
            : hidesPrivateDetails ? L10n.text("子代理") : node.title
        project = hidesPrivateDetails ? L10n.text("已隐藏项目") : family.title
        updatedAt = node.updatedAt
        subagentCount = 0
        subagentAllocatedBytes = 0
        allocatedBytes = node.attributedBytes
        databaseAttributedBytes = node.databaseAttributedBytes
        isFamily = false
        depth = max(1, node.depth)
    }
}

private struct AgentStorageChatIdentityCell: View {
    let row: AgentStorageChatRow
    let isExpanded: Bool
    let isExpanding: Bool
    let toggleExpanded: () -> Void
    let activate: () -> Void

    var body: some View {
        cell
    }

    private var cell: some View {
        HStack(spacing: 6) {
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
                .accessibilityLabel(L10n.text(isExpanded ? "折叠子代理" : "展开子代理"))
            } else {
                Color.clear.frame(width: 18, height: 24)
                    .accessibilityHidden(true)
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
            .simultaneousGesture(TapGesture().onEnded(activate))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAction(named: L10n.text("显示详情"), activate)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    private var accessibilityLabel: String {
        if row.isFamily {
            return "\(L10n.text("主聊天"))，\(row.title)，\(row.subagentCount) \(L10n.text("个子代理"))，\(AgentStorageSizeFormatter.string(row.allocatedBytes))"
        }
        return "\(L10n.text("子代理"))，\(row.title)，\(AgentStorageSizeFormatter.string(row.allocatedBytes))"
    }
}

private struct AgentStorageChatSelectionCell: View {
    let row: AgentStorageChatRow
    let isSelected: Bool
    let isPendingSynchronization: Bool
    let toggleSelection: () -> Void

    var body: some View {
        Group {
            if row.isFamily {
                if isPendingSynchronization {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.green)
                        .frame(width: 24, height: 28)
                        .help(L10n.text("已清理，等待同步确认"))
                        .accessibilityLabel(L10n.text("已清理，等待同步确认"))
                } else {
                    Button(action: toggleSelection) {
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            .frame(width: 24, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text(isSelected ? "取消选择" : "选择聊天"))
                    .accessibilityLabel(L10n.text(isSelected ? "取消选择" : "选择聊天"))
                    .accessibilityValue(isSelected ? L10n.text("已选择") : L10n.text("未选择"))
                }
            } else {
                Color.clear
                    .frame(width: 24, height: 28)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AgentStoragePageSelectionCheckbox: View {
    let state: AgentStorageBatchSelectionEngine.PageSelectionState
    let selectedCount: Int
    let totalCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
                .frame(width: 32, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(totalCount == 0)
        .help(actionTitle)
        .accessibilityLabel(actionTitle)
        .accessibilityValue(L10n.format("已选择 %d，共 %d 个聊天", selectedCount, totalCount))
        .accessibilityIdentifier("agent-storage-current-page-selection")
    }

    private var symbolName: String {
        switch state {
        case .none: "square"
        case .partial: "minus.square.fill"
        case .all: "checkmark.square.fill"
        }
    }

    private var actionTitle: String {
        L10n.text(state == .all ? "取消选择本页" : "选择本页")
    }
}

private struct AgentStorageTableDetailButton: View {
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(L10n.text("详情"), systemImage: "sidebar.right")
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(L10n.text("显示详情"))
        .accessibilityIdentifier(accessibilityIdentifier)
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
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
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
        .visualEffectMaterialBackground(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(.separator.opacity(0.55), lineWidth: 1)
        }
        .visualEffectShadow(color: .black.opacity(0.08), radius: 6, y: 2)
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
            Text("· \(L10n.number(summary.threadCount)) \(L10n.text("个主聊天"))")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AgentStorageLocationStrip: View {
    let sources: [AgentStorageSource]
    let hidesPrivateDetails: Bool

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                    if index > 0 {
                        Divider()
                            .frame(height: source.configuredPath == source.resolvedPath ? 54 : 72)
                            .padding(.horizontal, 14)
                    }
                    location(source)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .frame(minHeight: 76, maxHeight: 106)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.2))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-storage-locations")
    }

    private func location(_ source: AgentStorageSource) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: source.kind?.locationSymbol ?? "folder")
                    .foregroundStyle(.secondary)
                Text(L10n.text(source.displayName))
                    .font(.caption.weight(.semibold))
                Text(AgentStorageSizeFormatter.string(source.allocatedBytes))
                    .font(.caption.monospacedDigit().weight(.semibold))
                if !source.isAvailable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            HStack(spacing: 6) {
                Label(source.volumeName ?? L10n.text("未知磁盘"), systemImage: "externaldrive")
                Text("·")
                Text(discoveryLabel(source))
                if !source.alternateConfiguredPaths.isEmpty {
                    Text("·")
                    Text(L10n.format("%d 个路径指向同一位置", source.alternateConfiguredPaths.count + 1))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text(displayPath(source.configuredPath))
                .font(.caption2.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            if source.configuredPath != source.resolvedPath {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right")
                    Text(displayPath(source.resolvedPath))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 260, idealWidth: 320, maxWidth: 390, alignment: .leading)
    }

    private func discoveryLabel(_ source: AgentStorageSource) -> String {
        switch source.discoverySource {
        case .officialDefault: return L10n.text("默认目录")
        case .environmentVariable:
            return source.discoveryIdentifier ?? L10n.text("环境变量")
        case .knownClient: return L10n.text("已知客户端")
        case .userAdded: return L10n.text("手动添加")
        case .embeddedAgent: return L10n.text("嵌入式 Agent")
        case nil: return L10n.text("已发现目录")
        }
    }

    private func displayPath(_ path: String) -> String {
        hidesPrivateDetails ? L10n.text("路径已隐藏") : path
    }
}

private extension AgentStorageSourceKind {
    var locationSymbol: String {
        switch self {
        case .codexHome, .claudeCode, .openCode: "terminal"
        case .codexDesktop, .claudeDesktop: "macwindow"
        case .claudeDesktopAgent: "point.3.connected.trianglepath.dotted"
        case .rebuildableCache: "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }
}

@MainActor
struct AgentStorageProviderIcon: View {
    let provider: AgentStorageProvider
    let size: CGFloat
    private static let codexImage = loadImage(named: "codex-openai")
    private static let claudeImage = loadImage(named: "claude-code")
    private static let openCodeImage = loadImage(
        named: "opencode",
        fileExtension: "icns"
    )

    var body: some View {
        Group {
            if let image = providerImage {
                switch provider {
                case .codex:
                    Image(nsImage: image)
                        .resizable()
                        .renderingMode(.template)
                        .foregroundStyle(.primary)
                case .claude:
                    Image(nsImage: image)
                        .resizable()
                        .renderingMode(.template)
                        .foregroundStyle(Color(red: 0.82, green: 0.39, blue: 0.18))
                case .openCode:
                    Image(nsImage: image)
                        .resizable()
                        .renderingMode(.original)
                }
            } else {
                Image(systemName: fallbackSymbol)
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .scaledToFit()
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var providerImage: NSImage? {
        switch provider {
        case .codex: Self.codexImage
        case .claude: Self.claudeImage
        case .openCode: Self.openCodeImage
        }
    }

    private var fallbackSymbol: String {
        switch provider {
        case .codex: "terminal"
        case .claude: "sparkles"
        case .openCode: "curlybraces"
        }
    }

    private static func loadImage(
        named name: String,
        fileExtension: String = "png"
    ) -> NSImage? {
        guard let url = AppResourceBundle.value.url(forResource: name, withExtension: fileExtension) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private static func applicationIcon(
        bundleIdentifier: String,
        fallbackPath: String
    ) -> NSImage? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        guard FileManager.default.fileExists(atPath: fallbackPath) else { return nil }
        return NSWorkspace.shared.icon(forFile: fallbackPath)
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

private struct AgentStorageCleanupCompletedView: View {
    let completion: AgentStorageCleanupCompletion
    let reanalyze: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                completionHeader
                resultSummary
                    .padding(.top, 24)
                accuracyNotice
                    .padding(.top, 24)
                if let reanalyze {
                    Button(action: reanalyze) {
                        Label(L10n.text("重新分析"), systemImage: "arrow.clockwise")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 220, height: 46)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(AgentStoragePrimaryActionButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 24)
                    .accessibilityIdentifier("agent-storage-reanalyze-after-cleanup")
                }

                Label(
                    L10n.text("分析会增加 CPU 与磁盘读取，可随时停止。"),
                    systemImage: "speedometer"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 12)
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 32)
            .padding(.vertical, 72)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var completionHeader: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 72, height: 72)
                .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.green.opacity(0.2))
                }
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(L10n.text("清理已完成"))
                    .font(.title2.weight(.semibold))
                Label(completion.provider.displayName, systemImage: providerSymbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var resultSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                outcomeSummary
                Divider().frame(height: 18)
                releasedSummary
            }
            VStack(spacing: 8) {
                outcomeSummary
                releasedSummary
            }
        }
        .font(.callout.monospacedDigit())
    }

    private var outcomeSummary: some View {
        Text(L10n.format(
            "成功 %d · 跳过 %d · 失败 %d",
            completion.succeededCount,
            completion.skippedCount,
            completion.failedCount
        ))
        .foregroundStyle(.secondary)
    }

    private var releasedSummary: some View {
        Label(
            L10n.format(
                "实际复核释放 %@",
                AgentStorageSizeFormatter.string(completion.measuredReleasedBytes)
            ),
            systemImage: "internaldrive"
        )
        .fontWeight(.semibold)
    }

    private var accuracyNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("占用数据需要更新"))
                    .font(.callout.weight(.semibold))
                Text(L10n.text("旧的空间结果已隐藏，避免显示删除前的占用数据。重新分析后即可查看最新构成。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.54), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.56))
        }
    }

    private var providerSymbol: String {
        switch completion.provider {
        case .codex: "terminal"
        case .claude: "bubble.left.and.text.bubble.right"
        case .openCode: "curlybraces"
        }
    }
}

private struct AgentStorageAnalysisInvitation: View {
    let start: () -> Void
    @State private var isStartHovered = false

    private let contentMaxWidth: CGFloat = 760
    private let wideStepsMinimumWidth: CGFloat = 690
    private let wideStepWidth: CGFloat = 214

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                invitationHeader

                analysisSteps
                    .padding(.top, 32)

                performanceNotice
                    .padding(.top, 30)

                Button(action: start) {
                    HStack(spacing: 11) {
                        ZStack {
                            Circle()
                                .fill(.white.opacity(0.17))
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .bold))
                                .offset(x: 1)
                        }
                        .frame(width: 28, height: 28)

                        Text(L10n.text("开始分析"))
                            .font(.headline)

                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                            .opacity(0.78)
                    }
                    .foregroundStyle(.white)
                    .frame(width: 240, height: 52)
                    .background(
                        Color.accentColor.opacity(isStartHovered ? 0.92 : 1),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.white.opacity(0.18), lineWidth: 1)
                    }
                    .visualEffectShadow(
                        color: Color.accentColor.opacity(isStartHovered ? 0.30 : 0.20),
                        radius: isStartHovered ? 12 : 7,
                        y: isStartHovered ? 5 : 3
                    )
                }
                .buttonStyle(AgentStoragePrimaryActionButtonStyle())
                .keyboardShortcut(.defaultAction)
                .onHover { isStartHovered = $0 }
                .padding(.top, 26)
                .accessibilityHint(L10n.text("开始读取并测量 AI Agent 数据"))
                .accessibilityIdentifier("agent-storage-start-analysis")

                privacyNotice
                    .padding(.top, 12)
            }
            .frame(maxWidth: contentMaxWidth)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 32)
            .padding(.vertical, 52)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var invitationHeader: some View {
        VStack(spacing: 14) {
            analysisSymbol
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(L10n.text("尚未分析 AI Agent 空间"))
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(L10n.text("分析 Codex、Claude 和 OpenCode 的聊天、子代理与全局运行时"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var performanceNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "speedometer")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("性能提示"))
                    .font(.callout.weight(.semibold))
                Text(L10n.text("分析会增加 CPU 与磁盘读取，可随时停止。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
        }
    }

    private var privacyNotice: some View {
        Label(
            L10n.text("分析完全在本机进行；不会上传标题、路径或占用数据。"),
            systemImage: "lock.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var analysisSymbol: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.12))
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.20), lineWidth: 1)
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 29, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            ZStack {
                Circle().fill(Color.accentColor)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 25, height: 25)
            .overlay {
                Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 3)
            }
            .offset(x: 25, y: 24)
        }
        .frame(width: 72, height: 72)
    }

    private var analysisSteps: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                wideAnalysisStep(
                    symbol: "point.3.connected.trianglepath.dotted",
                    title: "建立聊天关系",
                    detail: "关联主聊天、子代理与项目"
                )
                wideAnalysisStep(
                    symbol: "internaldrive",
                    title: "测量实际占用",
                    detail: "读取文件系统分配空间"
                )
                wideAnalysisStep(
                    symbol: "square.3.layers.3d",
                    title: "整理空间归属",
                    detail: "区分聊天、全局与未归属数据"
                )
            }
            .frame(minWidth: wideStepsMinimumWidth, maxWidth: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 16) {
                compactAnalysisStep(
                    symbol: "point.3.connected.trianglepath.dotted",
                    title: "建立聊天关系",
                    detail: "关联主聊天、子代理与项目"
                )
                compactAnalysisStep(
                    symbol: "internaldrive",
                    title: "测量实际占用",
                    detail: "读取文件系统分配空间"
                )
                compactAnalysisStep(
                    symbol: "square.3.layers.3d",
                    title: "整理空间归属",
                    detail: "区分聊天、全局与未归属数据"
                )
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func wideAnalysisStep(
        symbol: String,
        title: String,
        detail: String
    ) -> some View {
        analysisStepContent(symbol: symbol, title: title, detail: detail)
            .frame(width: wideStepWidth, alignment: .topLeading)
            .frame(minHeight: 58, alignment: .topLeading)
    }

    private func compactAnalysisStep(
        symbol: String,
        title: String,
        detail: String
    ) -> some View {
        analysisStepContent(symbol: symbol, title: title, detail: detail)
            .frame(minHeight: 58, alignment: .topLeading)
    }

    private func analysisStepContent(
        symbol: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text(title))
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.text(detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct AgentStoragePrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct AgentStorageCompactToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.42)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct AgentStorageOverviewSkeleton: View {
    let progress: AgentStorageScanProgress
    let progressByProvider: [AgentStorageProvider: AgentStorageScanProgress]
    let startedAt: Date?

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
                    AgentStorageLiveProgressView(
                        progress: progress,
                        progressByProvider: progressByProvider,
                        startedAt: startedAt
                    )
                    .frame(maxWidth: 540)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)

                Divider()

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 370, maximum: 520), spacing: 16)],
                    alignment: .center,
                    spacing: 16
                ) {
                    ForEach(AgentStorageProvider.allCases) { _ in
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
    var progressByProvider: [AgentStorageProvider: AgentStorageScanProgress] = [:]
    var startedAt: Date?
    var compact = false
    @State private var showsProviderProgress = false

    @ViewBuilder
    var body: some View {
        if compact {
            HStack(spacing: 6) {
                Image(systemName: phaseSymbol)
                    .foregroundStyle(Color.accentColor)
                Text(headlineTitle)
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

    @ViewBuilder
    private var fullContent: some View {
        if progressByProvider.isEmpty {
            serialFullContent
        } else {
            parallelCompactContent
        }
    }

    private var serialFullContent: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Image(systemName: phaseSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(headlineTitle)
                        .font(.callout.weight(.semibold))
                    HStack(spacing: 6) {
                        Text(stagePositionText)
                        if let provider = progress.provider {
                            Text("·")
                            Text(provider.displayName)
                        }
                        if let databasePositionText {
                            Text("·")
                            Text(databasePositionText)
                        }
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                elapsedView
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(progressDetail)
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                    Text(phaseContext)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let fraction {
                ProgressView(value: fraction, total: 1)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            VStack(spacing: 5) {
                HStack(spacing: 4) {
                    ForEach(AgentStorageScanPhase.allCases, id: \.rawValue) { phase in
                        Capsule()
                            .fill(phase.rawValue <= progress.phase.rawValue
                                ? Color.accentColor.opacity(phase == progress.phase ? 1 : 0.42)
                                : Color.secondary.opacity(0.16))
                            .frame(height: 4)
                    }
                }
                HStack(spacing: 4) {
                    ForEach(AgentStorageScanPhase.allCases, id: \.rawValue) { phase in
                        Text(shortTitle(for: phase))
                            .font(.system(size: 9, weight: phase == progress.phase ? .semibold : .regular))
                            .foregroundStyle(phase == progress.phase ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            if let activitySummary {
                HStack(spacing: 6) {
                    Image(systemName: activitySymbol)
                        .foregroundStyle(Color.accentColor)
                    Text(activitySummary)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var parallelCompactContent: some View {
        Button {
            showsProviderProgress.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(
                        Color.accentColor.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 6)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(headlineTitle)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .layoutPriority(1)
                        Spacer(minLength: 8)
                        elapsedView
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 5) {
                        Text(providerCountSummary)
                            .fontWeight(.medium)
                            .fixedSize(horizontal: true, vertical: false)
                        Text("·")
                        Text(currentProviderSummary)
                            .truncationMode(.tail)
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    if let summaryProvider,
                       let summaryProgress {
                        providerProgressIndicator(summaryProvider, progress: summaryProgress)
                            .frame(height: 3)
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.46),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        }
        .help(L10n.format("查看全部 %d 个应用进度", progressByProvider.count))
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint(L10n.format("查看全部 %d 个应用进度", progressByProvider.count))
        .accessibilityIdentifier("agent-storage-provider-progress")
        .popover(isPresented: $showsProviderProgress, arrowEdge: .bottom) {
            providerProgressPopover
        }
    }

    private var providerProgressPopover: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text("应用分析进度"))
                        .font(.headline)
                    Text(providerCountSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                elapsedView
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    providerProgressRows
                }
            }
            .frame(height: min(CGFloat(progressByProvider.count) * 59, 354))
        }
        .frame(width: 500)
    }

    @ViewBuilder
    private var providerProgressRows: some View {
        let providers = orderedProviders
        ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
            if let providerProgress = progressByProvider[provider] {
                providerProgressRow(provider, progress: providerProgress)
                if index < providers.count - 1 {
                    Divider().padding(.leading, 38)
                }
            }
        }
    }

    private func providerProgressRow(
        _ provider: AgentStorageProvider,
        progress: AgentStorageScanProgress
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    AgentStorageProviderIcon(provider: provider, size: 18)
                    Text(provider.displayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .frame(width: 82, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(providerProgressIsComplete(progress)
                        ? L10n.text("分析完成")
                        : phaseTitle(for: progress))
                        .font(.caption.weight(.medium))
                    Text(progressDetail(for: progress))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    providerProgressIndicator(provider, progress: progress)
                    Text(activitySummary(for: progress) ?? stagePositionText(for: progress))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)

                providerProgressValue(progress)
                    .frame(width: 44, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    AgentStorageProviderIcon(provider: provider, size: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(provider.displayName)
                            .font(.caption.weight(.semibold))
                        Text(providerProgressIsComplete(progress)
                            ? L10n.text("分析完成")
                            : phaseTitle(for: progress))
                            .font(.caption2.weight(.medium))
                    }
                    Spacer(minLength: 8)
                    providerProgressValue(progress)
                }
                providerProgressIndicator(provider, progress: progress)
                HStack(spacing: 8) {
                    Text(progressDetail(for: progress))
                    Spacer(minLength: 4)
                    if let activitySummary = activitySummary(for: progress) {
                        Text(activitySummary)
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func providerProgressIndicator(
        _ provider: AgentStorageProvider,
        progress: AgentStorageScanProgress
    ) -> some View {
        if let fraction = fraction(for: progress) {
            ProgressView(value: fraction, total: 1)
                .progressViewStyle(.linear)
                .tint(providerProgressTint(provider))
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(providerProgressTint(provider))
        }
    }

    private func providerProgressTint(_ provider: AgentStorageProvider) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .yellow]
        let index = AgentStorageProvider.allCases.firstIndex(of: provider) ?? 0
        return palette[index % palette.count]
    }

    @ViewBuilder
    private func providerProgressValue(_ progress: AgentStorageScanProgress) -> some View {
        if providerProgressIsComplete(progress) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel(L10n.text("分析完成"))
        } else if let fraction = fraction(for: progress) {
            Text(fraction, format: .percent.precision(.fractionLength(0)))
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private func providerProgressIsComplete(_ progress: AgentStorageScanProgress) -> Bool {
        guard progress.phase == .organizingResults,
              let total = progress.totalCount else { return false }
        return progress.completedCount >= total
    }

    private var completedProviderCount: Int {
        progressByProvider.values.filter(providerProgressIsComplete).count
    }

    private var activeProviderCount: Int {
        max(0, progressByProvider.count - completedProviderCount)
    }

    private var providerCountSummary: String {
        L10n.format(
            "进行中 %d · 已完成 %d",
            activeProviderCount,
            completedProviderCount
        )
    }

    private var orderedProviders: [AgentStorageProvider] {
        AgentStorageProvider.allCases
            .filter { progressByProvider[$0] != nil }
            .sorted { lhs, rhs in
                guard let lhsProgress = progressByProvider[lhs],
                      let rhsProgress = progressByProvider[rhs] else { return false }
                let lhsComplete = providerProgressIsComplete(lhsProgress)
                let rhsComplete = providerProgressIsComplete(rhsProgress)
                if lhsComplete != rhsComplete { return !lhsComplete }
                return providerOrder(lhs, rhs)
            }
    }

    private var currentProvider: AgentStorageProvider? {
        let activeProviders = orderedProviders.filter {
            guard let providerProgress = progressByProvider[$0] else { return false }
            return !providerProgressIsComplete(providerProgress)
        }
        return activeProviders.min { lhs, rhs in
            guard let lhsProgress = progressByProvider[lhs],
                  let rhsProgress = progressByProvider[rhs] else { return false }
            if lhsProgress.phase != rhsProgress.phase {
                return lhsProgress.phase.rawValue < rhsProgress.phase.rawValue
            }
            let lhsFraction = fraction(for: lhsProgress) ?? 0
            let rhsFraction = fraction(for: rhsProgress) ?? 0
            if lhsFraction != rhsFraction { return lhsFraction < rhsFraction }
            return providerOrder(lhs, rhs)
        } ?? orderedProviders.first
    }

    private var currentProviderSummary: String {
        if activeProviderCount == 0 {
            return [phaseTitle(for: progress), progressDetail(for: progress)]
                .joined(separator: " · ")
        }
        guard let currentProvider,
              let currentProgress = progressByProvider[currentProvider] else {
            return L10n.text("正在准备应用分析")
        }
        return [
            currentProvider.displayName,
            providerProgressIsComplete(currentProgress)
                ? L10n.text("分析完成")
                : phaseTitle(for: currentProgress),
            progressDetail(for: currentProgress),
            activitySummary(for: currentProgress)
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    private var summaryProvider: AgentStorageProvider? {
        currentProvider ?? orderedProviders.first
    }

    private var summaryProgress: AgentStorageScanProgress? {
        if activeProviderCount == 0 { return progress }
        guard let currentProvider else { return nil }
        return progressByProvider[currentProvider]
    }

    private func providerOrder(
        _ lhs: AgentStorageProvider,
        _ rhs: AgentStorageProvider
    ) -> Bool {
        let allProviders = AgentStorageProvider.allCases
        return (allProviders.firstIndex(of: lhs) ?? 0) < (allProviders.firstIndex(of: rhs) ?? 0)
    }

    private var fraction: Double? {
        fraction(for: progress)
    }

    private func fraction(for progress: AgentStorageScanProgress) -> Double? {
        guard let total = progress.totalCount, total > 0 else { return nil }
        if total == 0 { return 1 }
        return min(1, Double(progress.completedCount) / Double(total))
    }

    @ViewBuilder
    private var elapsedView: some View {
        if let startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(L10n.format("已持续 %@", elapsedText(from: startedAt, to: context.date)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
        }
    }

    private var headlineTitle: String {
        guard !progressByProvider.isEmpty else { return phaseTitle }
        if activeProviderCount == 0 {
            return L10n.format("正在汇总 %d 个应用结果", progressByProvider.count)
        }
        return L10n.format("正在并行分析 %d 个应用", progressByProvider.count)
    }

    private var phaseTitle: String { phaseTitle(for: progress) }

    private func phaseTitle(for progress: AgentStorageScanProgress) -> String {
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
        case .attributingDatabase:
            switch progress.databaseStage {
            case .preparing, nil:
                L10n.text("正在检查日志数据库")
            case .readingRecords:
                L10n.text("正在读取数据库日志")
            case .mappingRecords:
                L10n.text("正在匹配聊天归属")
            }
        case .organizingResults:
            L10n.text("正在整理空间归属")
        }
    }

    private var progressDetail: String { progressDetail(for: progress) }

    private func progressDetail(for progress: AgentStorageScanProgress) -> String {
        switch progress.phase {
        case .discoveringSources:
            L10n.format("已发现 %d 个数据位置", progress.completedCount)
        case .readingMetadata:
            if let count = progress.activityCount, count > 0 {
                L10n.format("已读取 %d 项聊天索引", count)
            } else {
                L10n.text("正在打开当前聊天索引")
            }
        case .measuringEntries:
            L10n.format("已检查 %d 个文件与目录", progress.completedCount)
        case .attributingDatabase:
            switch progress.databaseStage {
            case .preparing, nil:
                L10n.text("正在确认数据库结构与只读快照")
            case .readingRecords:
                if let total = progress.totalCount, total > 0 {
                    L10n.format("已读取 %d / %d 条日志", min(progress.completedCount, total), total)
                } else if progress.completedCount > 0 {
                    L10n.format("已读取 %d 条日志", progress.completedCount)
                } else {
                    L10n.text("开始读取日志记录")
                }
            case .mappingRecords:
                L10n.format("正在匹配 %d 条日志", progress.completedCount)
            }
        case .validatingEntries, .organizingResults:
            if let total = progress.totalCount {
                L10n.format("已处理 %d / %d 项", min(progress.completedCount, total), total)
            } else {
                L10n.format("已处理 %d 项", progress.completedCount)
            }
        }
    }

    private var phaseContext: String {
        switch progress.phase {
        case .discoveringSources:
            L10n.text("正在检查 Codex、Claude、OpenCode 与自定义数据位置")
        case .readingMetadata:
            L10n.text("正在建立主聊天、子代理与项目关系")
        case .measuringEntries:
            L10n.text("正在读取文件系统分配的实际空间")
        case .validatingEntries:
            L10n.text("正在确认扫描期间发生的文件变化")
        case .attributingDatabase:
            if progress.databaseStage == .readingRecords, progress.totalCount == nil {
                L10n.text("记录总量将在读取完成后确认")
            } else {
                L10n.text("正在将共享数据库记录映射到对应聊天")
            }
        case .organizingResults:
            L10n.text("正在生成聊天、全局与未归属空间账本")
        }
    }

    private var activitySummary: String? { activitySummary(for: progress) }

    private func activitySummary(for progress: AgentStorageScanProgress) -> String? {
        guard let bytes = progress.processedBytes, bytes > 0 else { return nil }
        let value = AgentStorageSizeFormatter.string(bytes)
        switch progress.phase {
        case .measuringEntries:
            return L10n.format("已测量 %@", value)
        case .attributingDatabase:
            return L10n.format("累计日志估算空间 %@", value)
        default:
            return L10n.format("已读取 %@", value)
        }
    }

    private var activitySymbol: String {
        switch progress.phase {
        case .measuringEntries: "externaldrive.fill"
        case .attributingDatabase: "cylinder.split.1x2"
        default: "arrow.down.doc.fill"
        }
    }

    private var stagePositionText: String {
        stagePositionText(for: progress)
    }

    private func stagePositionText(for progress: AgentStorageScanProgress) -> String {
        L10n.format(
            "第 %d / %d 步",
            progress.phase.rawValue + 1,
            AgentStorageScanPhase.allCases.count
        )
    }

    private var databasePositionText: String? {
        guard progress.phase == .attributingDatabase,
              let index = progress.databaseIndex,
              let count = progress.databaseCount,
              count > 0 else { return nil }
        return L10n.format("数据库 %d / %d", min(index, count), count)
    }

    private var accessibilitySummary: String {
        if !progressByProvider.isEmpty {
            let providerSummaries = AgentStorageProvider.allCases.compactMap { provider -> String? in
                guard let value = progressByProvider[provider] else { return nil }
                return [
                    provider.displayName,
                    providerProgressIsComplete(value)
                        ? L10n.text("分析完成")
                        : phaseTitle(for: value),
                    progressDetail(for: value),
                    activitySummary(for: value)
                ]
                .compactMap { $0 }
                .joined(separator: "，")
            }
            return ([headlineTitle] + providerSummaries).joined(separator: "；")
        }
        return [phaseTitle, databasePositionText, progressDetail, phaseContext, activitySummary]
            .compactMap { $0 }
            .joined(separator: "，")
    }

    private func shortTitle(for phase: AgentStorageScanPhase) -> String {
        switch phase {
        case .discoveringSources: L10n.text("定位")
        case .readingMetadata: L10n.text("关系")
        case .measuringEntries: L10n.text("测量")
        case .validatingEntries: L10n.text("核对")
        case .attributingDatabase: L10n.text("归因")
        case .organizingResults: L10n.text("整理")
        }
    }

    private func elapsedText(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    private var phaseSymbol: String {
        switch progress.phase {
        case .discoveringSources: "externaldrive.badge.magnifyingglass"
        case .readingMetadata: "point.3.connected.trianglepath.dotted"
        case .measuringEntries: "doc.text.magnifyingglass"
        case .validatingEntries: "checkmark.shield"
        case .attributingDatabase: "cylinder.split.1x2"
        case .organizingResults: "chart.bar.doc.horizontal"
        }
    }
}

private struct AgentStorageRefreshingProgressView: View {
    let model: AgentStorageModel

    var body: some View {
        AgentStorageLiveProgressView(
            progress: model.progress,
            progressByProvider: model.progressByProvider,
            startedAt: model.scanStartedAt,
            compact: true
        )
    }
}

private enum AgentStorageResolvedDetail {
    case family(AgentStorageThreadFamily)
    case subagent(AgentStorageThreadNode, AgentStorageThreadFamily)
    case global(AgentStorageGlobalItem)
    case unattributed(AgentStorageUnattributedItem)
}

private struct AgentStorageCompactDetail: View {
    @Environment(\.dismiss) private var dismiss

    let detail: AgentStorageResolvedDetail?
    let hidesPrivateDetails: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(L10n.text("聊天详情"))
                    .font(.headline)
                Spacer()
                Button(action: dismiss.callAsFunction) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(AppIconButtonStyle(size: 30, isFramed: false))
                .help(L10n.text("关闭详情"))
                .accessibilityLabel(L10n.text("关闭详情"))
                .accessibilityIdentifier("agent-storage-close-compact-detail")
            }
            .padding(.horizontal, 18)
            .frame(height: 50)
            .background(.bar)
            Divider()
            AgentStorageDetailView(detail: detail, hidesPrivateDetails: hidesPrivateDetails)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: dismiss.callAsFunction)
    }
}

private struct AgentStorageTransientDetail: View {
    let detail: AgentStorageResolvedDetail?
    let hidesPrivateDetails: Bool
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(L10n.text("详情"))
                    .font(.headline)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(AppIconButtonStyle(size: 30, isFramed: false))
                .help(L10n.text("关闭详情"))
                .accessibilityLabel(L10n.text("关闭详情"))
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            AgentStorageDetailView(detail: detail, hidesPrivateDetails: hidesPrivateDetails)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .visualEffectShadow(color: .black.opacity(0.16), radius: 14, x: -4, y: 0)
        .onExitCommand(perform: close)
    }
}

private struct AgentStorageDetailView: View {
    @AppStorage(AgentStoragePreferences.mockTitlesKey) private var usesMockTitles = false
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
                    .padding(.horizontal, 18)
                    .padding(.vertical, 20)
                }
            } else {
                ContentUnavailableView(
                    L10n.text("选择一项查看详情"),
                    systemImage: "sidebar.right"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func familyDetail(_ family: AgentStorageThreadFamily) -> some View {
        detailHeader(
            provider: family.provider,
            title: privateTitle(
                family.title,
                provider: family.provider,
                nativeID: family.nativeThreadID,
                isSubagent: false,
                fallback: L10n.text("聊天")
            ),
            subtitle: hidesPrivateDetails
                ? L10n.text("项目已隐藏")
                : localizedAgentStorageProjectName(family.project),
            path: hidesPrivateDetails ? nil : family.path
        )
        familyStorageHero(family)
        familyStorageBreakdown(family)
        if !family.composition.isEmpty {
            detailSection(L10n.text("会话文件构成"), symbol: "square.stack.3d.up.fill") {
                ForEach(family.composition.sorted { $0.value > $1.value }, id: \.key) { item in
                    compositionRow(
                        title: item.key.localizedTitle,
                        symbol: item.key.detailSymbol,
                        bytes: item.value,
                        total: max(1, family.allocatedBytes),
                        color: item.key.detailColor
                    )
                }
            }
        }
        if !family.subagents.isEmpty {
            let largestSubagents = family.largestSubagents(limit: 5)
            detailSection(L10n.text("最大子代理"), symbol: "point.3.connected.trianglepath.dotted") {
                VStack(spacing: 0) {
                    ForEach(Array(largestSubagents.enumerated()), id: \.element.id) { index, node in
                        rankedSubagentRow(
                            node,
                            rank: index + 1,
                            total: family.attributedBytes,
                            provider: family.provider
                        )
                        if index < largestSubagents.count - 1 {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
            }
        }
        evidenceSection(
            id: family.nativeThreadID,
            path: hidesPrivateDetails ? nil : family.path,
            evidence: family.databaseAttributedBytes > 0
                ? databaseEvidence(for: family.provider)
                : L10n.text("主聊天及全部递归子代理的独占文件")
        )
    }

    private func databaseEvidence(for provider: AgentStorageProvider) -> String {
        switch provider {
        case .codex:
            return L10n.text("包含主聊天及递归子代理的独占文件，以及按 Codex 日志记录归入此聊天的数据库估算。")
        case .claude, .openCode:
            return L10n.text("包含主聊天及递归子代理的独占文件，以及按 Agent 会话记录归入此聊天的数据库估算。")
        }
    }

    private func familyStorageHero(_ family: AgentStorageThreadFamily) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("聊天总占用"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(AgentStorageSizeFormatter.string(family.attributedBytes))
                        .font(.system(size: 30, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(L10n.text("最近活动"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(L10n.relativeDate(family.updatedAt))
                        .font(.callout.weight(.medium))
                }
            }
            GeometryReader { geometry in
                let total = max(1, Double(family.attributedBytes))
                HStack(spacing: 2) {
                    detailSegment(
                        .accentColor,
                        bytes: clampedSum(family.mainAllocatedBytes, family.mainDatabaseAttributedBytes),
                        total: total,
                        width: geometry.size.width
                    )
                    detailSegment(
                        .teal,
                        bytes: clampedSum(family.subagentAllocatedBytes, family.subagentDatabaseAttributedBytes),
                        total: total,
                        width: geometry.size.width
                    )
                    detailSegment(
                        .secondary.opacity(0.45),
                        bytes: family.familyOtherAllocatedBytes,
                        total: total,
                        width: geometry.size.width
                    )
                }
            }
            .frame(height: 9)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
            HStack(alignment: .top, spacing: 12) {
                detailLegend(
                    L10n.text("主聊天"),
                    bytes: clampedSum(family.mainAllocatedBytes, family.mainDatabaseAttributedBytes),
                    color: .accentColor
                )
                detailLegend(
                    L10n.text("子代理"),
                    bytes: clampedSum(family.subagentAllocatedBytes, family.subagentDatabaseAttributedBytes),
                    color: .teal
                )
                if family.familyOtherAllocatedBytes > 0 {
                    detailLegend(
                        L10n.text("其他"),
                        bytes: family.familyOtherAllocatedBytes,
                        color: .secondary.opacity(0.55)
                    )
                }
            }
        }
        .padding(16)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.62),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
        }
    }

    private func familyStorageBreakdown(_ family: AgentStorageThreadFamily) -> some View {
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                detailSummaryBlock(
                    title: L10n.text("会话文件占用"),
                    note: L10n.text("线程独占，按文件实测"),
                    value: family.allocatedBytes,
                    symbol: "doc.fill",
                    color: .cyan
                )
                detailSummaryBlock(
                    title: L10n.text("数据库归因占用"),
                    note: L10n.text("共享日志库，按记录估算"),
                    value: family.databaseAttributedBytes,
                    symbol: "cylinder.fill",
                    color: .orange
                )
            }
            VStack(spacing: 10) {
                detailSummaryBlock(
                    title: L10n.text("会话文件占用"),
                    note: L10n.text("线程独占，按文件实测"),
                    value: family.allocatedBytes,
                    symbol: "doc.fill",
                    color: .cyan
                )
                detailSummaryBlock(
                    title: L10n.text("数据库归因占用"),
                    note: L10n.text("共享日志库，按记录估算"),
                    value: family.databaseAttributedBytes,
                    symbol: "cylinder.fill",
                    color: .orange
                )
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func detailSummaryBlock(
        title: String,
        note: String,
        value: UInt64,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(AgentStorageSizeFormatter.string(value))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(color.opacity(0.24), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func compositionRow(
        title: String,
        symbol: String,
        bytes: UInt64,
        total: UInt64,
        color: Color
    ) -> some View {
        let share = min(1, Double(bytes) / Double(total))
        return HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            Text(title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(AgentStorageSizeFormatter.string(bytes))
                    .font(.callout.weight(.medium).monospacedDigit())
                Text(share, format: .percent.precision(.fractionLength(0)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func detailSegment(
        _ color: Color,
        bytes: UInt64,
        total: Double,
        width: CGFloat
    ) -> some View {
        color.frame(width: max(bytes == 0 ? 0 : 2, width * CGFloat(Double(bytes) / total)))
    }

    private func detailLegend(_ title: String, bytes: UInt64, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7).padding(.top, 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(AgentStorageSizeFormatter.string(bytes))
                    .font(.caption.weight(.medium).monospacedDigit())
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func rankedSubagentRow(
        _ node: AgentStorageThreadNode,
        rank: Int,
        total: UInt64,
        provider: AgentStorageProvider
    ) -> some View {
        let share = total == 0 ? 0 : min(1, Double(node.attributedBytes) / Double(total))
        return HStack(spacing: 10) {
            Text(L10n.number(rank))
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(rank == 1 ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    rank == 1 ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 6)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(privateTitle(
                    node.title,
                    provider: provider,
                    nativeID: node.nativeID,
                    isSubagent: true,
                    fallback: L10n.text("子代理")
                ))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(shortIdentifier(node.nativeID))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(AgentStorageSizeFormatter.string(node.attributedBytes))
                    .font(.callout.weight(.medium).monospacedDigit())
                Text(share, format: .percent.precision(.fractionLength(0)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func subagentDetail(
        _ node: AgentStorageThreadNode,
        family: AgentStorageThreadFamily
    ) -> some View {
        let parentTitle = privateTitle(
            family.title,
            provider: family.provider,
            nativeID: family.nativeThreadID,
            isSubagent: false,
            fallback: L10n.text("聊天")
        )
        let childTitle = privateTitle(
            node.title,
            provider: family.provider,
            nativeID: node.nativeID,
            isSubagent: true,
            fallback: L10n.text("子代理")
        )
        detailHeader(
            provider: family.provider,
            title: childTitle,
            subtitle: hidesPrivateDetails
                ? L10n.text("主聊天 > 子代理")
                : "\(parentTitle) > \(childTitle)",
            path: hidesPrivateDetails ? nil : node.path
        )
        detailSection(L10n.text("占用摘要")) {
            detailValue(L10n.text("子代理占用"), node.attributedBytes, emphasized: true)
            detailValue(L10n.text("独占文件"), node.allocatedBytes)
            if node.databaseAttributedBytes > 0 {
                detailValue(L10n.text("数据库记录（估算）"), node.databaseAttributedBytes)
            }
            LabeledContent(L10n.text("文件"), value: L10n.number(node.artifactCount))
            LabeledContent(L10n.text("层级"), value: L10n.number(node.depth))
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
            if item.category == .sharedDatabase, item.databaseAttributedBytes > 0 {
                detailValue(L10n.text("日志数据库物理占用"), item.physicalAllocatedBytes, emphasized: true)
                detailValue(L10n.text("已归属到当前聊天"), item.databaseAttributedBytes)
                detailValue(L10n.text("共享数据库残差"), item.allocatedBytes)
            } else {
                detailValue(L10n.text("物理占用"), item.allocatedBytes, emphasized: true)
            }
            detailValue(L10n.text("逻辑大小"), item.logicalBytes)
            LabeledContent(L10n.text("文件"), value: L10n.number(item.artifactCount))
        }
        evidenceSection(
            id: item.id,
            path: hidesPrivateDetails ? nil : item.path,
            evidence: globalEvidence(item.category, provider: item.provider)
        )
    }

    private func globalEvidence(
        _ category: AgentStorageGlobalCategory,
        provider: AgentStorageProvider?
    ) -> String {
        switch category {
        case .sharedDatabase:
            if provider == .codex {
                return L10n.text("数据库记录按 Codex 提供的估算归入聊天；空闲页、索引、WAL 和无法关联的记录继续保留在共享残差中，物理总量只计算一次。")
            }
            return L10n.text("数据库记录按 Agent 会话记录估算归入聊天；空闲页、索引、WAL 和无法关联的记录继续保留在共享残差中，物理总量只计算一次。")
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
            LabeledContent(L10n.text("文件"), value: L10n.number(item.artifactCount))
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
                    .buttonStyle(AppIconButtonStyle(size: 30, isFramed: false))
                    .help(L10n.text("在 Finder 中显示"))
                    .accessibilityLabel(L10n.text("在 Finder 中显示"))
            }
        }
    }

    private func detailSection<Content: View>(
        _ title: String,
        symbol: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(14)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.58),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
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

    private func clampedSum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }

    private func evidenceSection(id: String, path: String?, evidence: String) -> some View {
        detailSection(L10n.text("占用依据"), symbol: "checkmark.shield.fill") {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 1)
                Text(evidence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label {
                Text(shortIdentifier(id))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "number")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2.monospaced())
            .textSelection(.enabled)

            if let path {
                Label {
                    Text(path)
                        .lineLimit(3)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "folder")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
    }

    private func privateTitle(
        _ title: String,
        provider: AgentStorageProvider,
        nativeID: String,
        isSubagent: Bool,
        fallback: String
    ) -> String {
        if usesMockTitles {
            return AgentStorageMockTitleCatalog.title(
                provider: provider,
                nativeID: nativeID,
                isSubagent: isSubagent
            )
        }
        return hidesPrivateDetails ? "\(provider.displayName) \(fallback)" : title
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func shortIdentifier(_ value: String) -> String {
        value.count > 20 ? "\(value.prefix(10))…\(value.suffix(6))" : value
    }
}

enum AgentStorageSizeFormatter {
    static func string(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if bytes >= 1 << 30 {
            return String(format: "%.2f GiB", locale: L10n.locale, value / Double(1 << 30))
        }
        if bytes >= 1 << 20 {
            return String(format: "%.1f MiB", locale: L10n.locale, value / Double(1 << 20))
        }
        if bytes >= 1 << 10 {
            return String(format: "%.1f KiB", locale: L10n.locale, value / Double(1 << 10))
        }
        return "\(L10n.number(bytes)) B"
    }
}

extension AgentStorageProvider {
    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .openCode: "OpenCode"
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
        case .conversation: L10n.text("会话文件")
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

    var detailColor: Color {
        switch self {
        case .conversation: .accentColor
        case .toolResult: .orange
        case .subagent: .teal
        case .fileHistory: .indigo
        case .attachment: .pink
        case .snapshot: .cyan
        case .task, .workflow: .green
        case .other: .secondary
        }
    }

    var detailSymbol: String {
        switch self {
        case .conversation: "bubble.left.and.text.bubble.right.fill"
        case .toolResult: "terminal.fill"
        case .subagent: "point.3.connected.trianglepath.dotted"
        case .fileHistory: "clock.arrow.circlepath"
        case .attachment: "paperclip"
        case .snapshot: "camera.viewfinder"
        case .task: "checkmark.circle.fill"
        case .workflow: "arrow.triangle.branch"
        case .other: "doc.fill"
        }
    }
}
