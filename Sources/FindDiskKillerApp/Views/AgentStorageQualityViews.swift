import FindDiskKillerCore
import SwiftUI

struct AgentStorageQualityPresentation: Equatable {
    let isPhysicalMeasurementComplete: Bool
    let attributionStatus: AgentStorageAttributionStatus
    let totalDiagnosticCount: Int
    let attributionDiagnosticCount: Int
    let physicalDiagnosticCount: Int
    let knownAffectedBytes: UInt64
    let hasUnknownAffectedBytes: Bool

    init(snapshot: AgentStorageSnapshot) {
        isPhysicalMeasurementComplete = snapshot.coverage.isPhysicalMeasurementComplete
        totalDiagnosticCount = snapshot.diagnostics.count
        attributionDiagnosticCount = snapshot.diagnostics.count {
            $0.impact != .physicalMeasurement
        }
        physicalDiagnosticCount = snapshot.diagnostics.count {
            $0.impact == .physicalMeasurement
        }
        knownAffectedBytes = Self.uniqueKnownAffectedBytes(snapshot.diagnostics)
        hasUnknownAffectedBytes = snapshot.diagnostics.contains {
            $0.affectedAllocatedBytes == nil && $0.impact != .chatMetadata
        }
        if snapshot.providers.contains(where: { $0.attributionStatus == .partial }) {
            attributionStatus = .partial
        } else if snapshot.providers.contains(where: { $0.attributionStatus == .complete }) {
            attributionStatus = .complete
        } else if snapshot.providers.contains(where: { $0.attributionStatus == .unavailable }) {
            attributionStatus = .unavailable
        } else {
            attributionStatus = .noConversationSource
        }
    }

    init(
        coverage: AgentStorageCoverage,
        summary: AgentStorageProviderSummary,
        diagnostics: [AgentStorageDiagnostic]
    ) {
        isPhysicalMeasurementComplete = coverage.isPhysicalMeasurementComplete
        attributionStatus = summary.attributionStatus
        totalDiagnosticCount = diagnostics.count
        attributionDiagnosticCount = diagnostics.count { $0.impact != .physicalMeasurement }
        physicalDiagnosticCount = diagnostics.count { $0.impact == .physicalMeasurement }
        knownAffectedBytes = summary.knownAffectedBytes
        hasUnknownAffectedBytes = diagnostics.contains {
            $0.affectedAllocatedBytes == nil && $0.impact != .chatMetadata
        }
    }

    private static func uniqueKnownAffectedBytes(
        _ diagnostics: [AgentStorageDiagnostic]
    ) -> UInt64 {
        var seen = Set<String>()
        return diagnostics.reduce(0) { total, diagnostic in
            guard let bytes = diagnostic.affectedAllocatedBytes else { return total }
            let key = diagnostic.relativePath.map {
                "\(diagnostic.sourceID)|\($0)"
            } ?? diagnostic.id
            guard seen.insert(key).inserted else { return total }
            return total.addingClampedForQuality(bytes)
        }
    }
}

struct AgentStorageQualityDetails: Identifiable {
    let id: String
    let provider: AgentStorageProvider?
    let presentation: AgentStorageQualityPresentation
    let sections: [AgentStorageDiagnosticSection]
    let sourceNames: [String: String]

    init(
        snapshot: AgentStorageSnapshot,
        provider: AgentStorageProvider?
    ) {
        id = provider?.rawValue ?? "all"
        self.provider = provider
        let diagnostics = provider.map(snapshot.diagnostics(for:)) ?? snapshot.diagnostics
        if let summary = provider.flatMap({ selected in
            snapshot.providers.first { $0.provider == selected }
        }) {
            presentation = AgentStorageQualityPresentation(
                coverage: snapshot.coverage,
                summary: summary,
                diagnostics: diagnostics
            )
        } else {
            presentation = AgentStorageQualityPresentation(snapshot: snapshot)
        }
        self.sections = Dictionary(grouping: diagnostics, by: \.area)
            .map { AgentStorageDiagnosticSection(area: $0.key, diagnostics: $0.value) }
            .sorted { $0.area.sortOrder < $1.area.sortOrder }
        sourceNames = Dictionary(uniqueKeysWithValues: snapshot.sources.map {
            ($0.id, $0.displayName)
        })
    }
}

struct AgentStorageDiagnosticSection: Identifiable {
    var id: AgentStorageDiagnosticArea { area }
    let area: AgentStorageDiagnosticArea
    let diagnostics: [AgentStorageDiagnostic]

    init(area: AgentStorageDiagnosticArea, diagnostics: [AgentStorageDiagnostic]) {
        self.area = area
        self.diagnostics = diagnostics.sorted { $0.id < $1.id }
    }
}

struct AgentStorageQualityStatusCluster: View {
    let presentation: AgentStorageQualityPresentation
    let showDetails: (() -> Void)?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                qualityLabel(
                    text: physicalStatusText,
                    symbol: "externaldrive.fill",
                    color: presentation.isPhysicalMeasurementComplete ? .green : .orange
                )
                attributionControl(compact: false)
            }
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.fill")
                    .foregroundStyle(presentation.isPhysicalMeasurementComplete ? .green : .orange)
                attributionControl(compact: true)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func attributionControl(compact: Bool) -> some View {
        let label = qualityLabel(
            text: compact ? compactAttributionText : attributionStatusText,
            symbol: attributionSymbol,
            color: attributionColor
        )
        if let showDetails {
            Button(action: showDetails) { label }
                .buttonStyle(.plain)
                .help(L10n.text("查看数据完整性详情"))
        } else {
            label
        }
    }

    private func qualityLabel(text: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var physicalStatusText: String {
        L10n.text(presentation.isPhysicalMeasurementComplete ? "空间统计完整" : "空间统计不完整")
    }

    private var compactAttributionText: String {
        presentation.attributionDiagnosticCount > 0
            ? L10n.format("%d 个归因问题", presentation.attributionDiagnosticCount)
            : attributionStatusText
    }

    private var attributionStatusText: String {
        switch presentation.attributionStatus {
        case .complete: L10n.text("聊天归因完整")
        case .partial:
            presentation.attributionDiagnosticCount > 0
                ? L10n.format(
                    "聊天归因有 %d 个问题",
                    presentation.attributionDiagnosticCount
                )
                : L10n.text("聊天归因部分完整")
        case .unavailable: L10n.text("聊天归因不可用")
        case .noConversationSource: L10n.text("未发现聊天数据")
        }
    }

    private var attributionSymbol: String {
        switch presentation.attributionStatus {
        case .complete: "bubble.left.and.bubble.right.fill"
        case .partial: "exclamationmark.bubble.fill"
        case .unavailable: "exclamationmark.bubble.fill"
        case .noConversationSource: "bubble.left.and.bubble.right"
        }
    }

    private var attributionColor: Color {
        switch presentation.attributionStatus {
        case .complete: .green
        case .partial, .unavailable: .orange
        case .noConversationSource: .secondary
        }
    }
}

struct AgentStorageQualityBar: View {
    let presentation: AgentStorageQualityPresentation
    let showDetails: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text(summaryText)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button(L10n.text("查看详情"), action: showDetails)
                .buttonStyle(.link)
        }
        .font(.caption)
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }

    private var summaryText: String {
        var parts: [String]
        switch (
            presentation.isPhysicalMeasurementComplete,
            presentation.attributionDiagnosticCount > 0
        ) {
        case (true, true):
            parts = [L10n.format(
                "空间占用已完整统计；%d 个归因问题可能影响聊天明细。",
                presentation.attributionDiagnosticCount
            )]
        case (false, true):
            parts = [L10n.format(
                "空间统计有 %d 个问题；聊天归因另有 %d 个问题。",
                presentation.physicalDiagnosticCount,
                presentation.attributionDiagnosticCount
            )]
        case (false, false):
            parts = [L10n.format(
                "空间统计有 %d 个问题；已识别聊天的归因保持完整。",
                presentation.physicalDiagnosticCount
            )]
        case (true, false):
            parts = [L10n.text("空间占用与聊天归因均已完整确认。")]
        }
        if presentation.knownAffectedBytes > 0 {
            parts.append(L10n.format(
                "已知涉及 %@。",
                AgentStorageSizeFormatter.string(presentation.knownAffectedBytes)
            ))
        }
        if presentation.hasUnknownAffectedBytes {
            parts.append(L10n.text("部分影响范围未知。"))
        }
        return parts.joined(separator: " ")
    }
}

struct AgentStorageQualityDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    let details: AgentStorageQualityDetails
    let hidesPrivateDetails: Bool
    let reanalyze: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                ForEach(details.sections) { section in
                    Section(section.area.displayTitle) {
                        ForEach(section.diagnostics) { diagnostic in
                            diagnosticRow(diagnostic)
                        }
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Text(L10n.text("诊断详情来自本次分析结果；打开此窗口不会再次读取 Agent 数据。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("完成")) { dismiss() }
                    .buttonStyle(AppActionButtonStyle(kind: .secondary, size: .large))
                if let reanalyze {
                    Button {
                        dismiss()
                        Task { @MainActor in
                            await Task.yield()
                            reanalyze()
                        }
                    } label: {
                        Label(L10n.text("重新分析"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(AppActionButtonStyle(kind: .primary, size: .large))
                }
            }
            .padding(16)
        }
        .frame(minWidth: 660, idealWidth: 720, minHeight: 520, idealHeight: 620)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("数据完整性"))
                        .font(.title2.weight(.semibold))
                    Text(details.provider?.displayName ?? L10n.text("AI 空间"))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(L10n.format(
                    "%d 个问题",
                    details.presentation.totalDiagnosticCount
                ))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 26) {
                summaryMetric(
                    title: L10n.text("空间统计"),
                    value: L10n.text(details.presentation.isPhysicalMeasurementComplete
                        ? "完整"
                        : "不完整"),
                    symbol: "externaldrive.fill",
                    color: details.presentation.isPhysicalMeasurementComplete ? .green : .orange
                )
                summaryMetric(
                    title: L10n.text("聊天归因"),
                    value: attributionValue,
                    symbol: "bubble.left.and.bubble.right.fill",
                    color: details.presentation.attributionStatus == .complete ? .green : .orange
                )
            }
        }
        .padding(20)
    }

    private func summaryMetric(
        title: String,
        value: String,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.callout.weight(.medium))
            }
        }
    }

    private var attributionValue: String {
        switch details.presentation.attributionStatus {
        case .complete: L10n.text("完整")
        case .partial: L10n.text("部分完整")
        case .unavailable: L10n.text("不可用")
        case .noConversationSource: L10n.text("未发现聊天数据")
        }
    }

    private func diagnosticRow(_ diagnostic: AgentStorageDiagnostic) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: diagnostic.kind.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(diagnostic.impact == .physicalMeasurement ? .red : .orange)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(diagnostic.kind.displayTitle)
                    .font(.callout.weight(.semibold))
                Text(diagnostic.kind.impactDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 7) {
                    Text(details.sourceNames[diagnostic.sourceID] ?? diagnostic.provider.displayName)
                    if !hidesPrivateDetails, let path = diagnostic.relativePath {
                        Text("·")
                        Text(path).lineLimit(1).truncationMode(.middle)
                    }
                    Text("·")
                    Text(impactText(diagnostic))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if diagnostic.affectedEntityCount > 1 {
                Text(L10n.format("%d 项", diagnostic.affectedEntityCount))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private func impactText(_ diagnostic: AgentStorageDiagnostic) -> String {
        if let bytes = diagnostic.affectedAllocatedBytes {
            return L10n.format("涉及 %@", AgentStorageSizeFormatter.string(bytes))
        }
        if diagnostic.impact == .chatMetadata {
            return L10n.text("不影响已确认的空间统计")
        }
        return L10n.text("影响范围未知")
    }
}

private extension AgentStorageDiagnosticArea {
    var sortOrder: Int {
        switch self {
        case .mainChat: 0
        case .subagent: 1
        case .toolResult: 2
        case .dataSource: 3
        case .database: 4
        case .fileSystem: 5
        }
    }

    var displayTitle: String {
        switch self {
        case .mainChat: L10n.text("主聊天")
        case .subagent: L10n.text("子代理")
        case .toolResult: L10n.text("工具结果")
        case .dataSource: L10n.text("数据源")
        case .database: L10n.text("数据库")
        case .fileSystem: L10n.text("文件系统")
        }
    }
}

private extension AgentStorageDiagnosticKind {
    var displayTitle: String {
        switch self {
        case .sourceUnreadable: L10n.text("数据源当前无法读取")
        case .sourceUnsupportedFormat: L10n.text("数据源格式暂不支持")
        case .mainTranscriptUnreadable: L10n.text("主聊天记录无法验证")
        case .sessionIdentityMismatch: L10n.text("聊天身份与文件名不一致")
        case .malformedTranscriptRecords: L10n.text("聊天中包含损坏记录")
        case .subagentTranscriptUnverified: L10n.text("子代理记录无法验证")
        case .subagentMetadataOnly: L10n.text("子代理只有元数据")
        case .ambiguousToolResult: L10n.text("工具结果无法唯一归属")
        case .databaseRecordUnverified: L10n.text("数据库记录无法验证")
        case .databaseAttributionUnavailable: L10n.text("数据库占用无法归因")
        case .relationshipConflict: L10n.text("主聊天与子代理关系冲突")
        case .filesystemEntrySkipped: L10n.text("文件系统条目未能读取")
        case .changedDuringScan: L10n.text("文件在分析期间发生变化")
        }
    }

    var impactDescription: String {
        switch self {
        case .sourceUnreadable:
            L10n.text("该位置的聊天列表可能缺失；已读取文件的物理占用仍会统计。")
        case .sourceUnsupportedFormat:
            L10n.text("物理占用已统计，但当前格式中的聊天无法可靠识别。")
        case .mainTranscriptUnreadable:
            L10n.text("该主聊天可能未出现在列表中，文件占用仍会归入全局或未归属。")
        case .sessionIdentityMismatch:
            L10n.text("为避免错误归因，该文件不会绑定到文件名所示的聊天。")
        case .malformedTranscriptRecords:
            L10n.text("聊天身份已确认，仅标题、项目或活动时间可能不完整。")
        case .subagentTranscriptUnverified:
            L10n.text("子代理明细可能缺失，相关文件仍会计入物理占用。")
        case .subagentMetadataOnly:
            L10n.text("可识别子代理，但没有可验证的 transcript，明细可能不完整。")
        case .ambiguousToolResult:
            L10n.text("文件已计入对应聊天，但无法可靠归属到具体主聊天或子代理。")
        case .databaseRecordUnverified:
            L10n.text("无法验证的记录不会参与聊天映射，数据库文件本身仍计入占用。")
        case .databaseAttributionUnavailable:
            L10n.text("数据库物理占用已统计，但无法估算到具体聊天。")
        case .relationshipConflict:
            L10n.text("冲突关系会被排除，避免把子代理错误归入其他主聊天。")
        case .filesystemEntrySkipped:
            L10n.text("该条目未进入物理统计，因此总占用可能偏低。")
        case .changedDuringScan:
            L10n.text("为避免使用不一致的数据，该文件的结果被标记为不稳定。")
        }
    }

    var symbol: String {
        switch self {
        case .sourceUnreadable, .filesystemEntrySkipped: "folder.badge.questionmark"
        case .sourceUnsupportedFormat: "doc.badge.ellipsis"
        case .mainTranscriptUnreadable, .malformedTranscriptRecords: "text.badge.xmark"
        case .sessionIdentityMismatch: "person.crop.circle.badge.questionmark"
        case .subagentTranscriptUnverified, .subagentMetadataOnly: "point.3.connected.trianglepath.dotted"
        case .ambiguousToolResult: "arrow.triangle.branch"
        case .databaseRecordUnverified, .databaseAttributionUnavailable: "cylinder.split.1x2"
        case .relationshipConflict: "arrow.trianglehead.branch"
        case .changedDuringScan: "arrow.triangle.2.circlepath"
        }
    }
}

private extension UInt64 {
    func addingClampedForQuality(_ other: UInt64) -> UInt64 {
        let result = addingReportingOverflow(other)
        return result.overflow ? .max : result.partialValue
    }
}
