import AppKit
import FindDiskKillerCore
import SwiftUI

struct StorageMapDashboardView: View {
    @Binding var scope: StorageMapScope

    let items: [StorageMapDashboardItem]
    let volumes: [StorageVolumeSnapshot]
    let analyzedBytes: UInt64?
    let entryCount: Int?
    let scannedAt: Date?
    let analysisActivity: StorageMapAnalysisActivity?
    let safeCleanupBytes: UInt64
    let isPresentingLiveResults: Bool
    let errorMessage: String?
    let skippedEntryCount: Int
    let conflictBytes: UInt64
    let safeCleanupBytesBySource: [StorageSourceID: UInt64]
    let isAnalysisRunning: Bool
    let isStopping: Bool
    let canAnalyze: Bool
    let openAvailability: (StorageSourceID) -> StorageSourceResultAccess
    let unavailableMessage: (StorageSourceID, StorageSourceResultAccess) -> String
    let canReanalyze: (StorageSourceID) -> Bool
    let openSource: (StorageSourceID) -> String?
    let reanalyze: (StorageSourceID) -> Void
    let startAnalysis: () -> Void
    let stopAnalysis: () -> Void
    let openSafeCleanup: () -> Void

    private var dashboardData: StorageMapDashboardData {
        StorageMapDashboardData(
            items: items,
            volumes: volumes,
            safeCleanupBytesBySource: safeCleanupBytesBySource
        )
    }

    var body: some View {
        // Build the volume/source projection once per dashboard update. This
        // projection used to be recomputed once for every child of the hero
        // and table, including its sorting and localized title map.
        let data = dashboardData

        GeometryReader { proxy in
            let contentWidth = max(0, proxy.size.width - 40)
            ScrollView {
                dashboardContent(data: data, availableWidth: contentWidth)
                    .padding(20)
            }
            .scrollIndicators(.visible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(InstrumentDesign.Palette.canvas)
    }

    private func dashboardContent(
        data: StorageMapDashboardData,
        availableWidth: CGFloat
    ) -> some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            StorageMapDashboardHeader(
                analyzedBytes: analyzedBytes,
                entryCount: entryCount,
                volumeCount: volumes.count,
                scannedAt: scannedAt,
                analysisActivity: analysisActivity,
                safeCleanupBytes: safeCleanupBytes,
                isPresentingLiveResults: isPresentingLiveResults,
                isAnalysisRunning: isAnalysisRunning,
                isStopping: isStopping,
                canAnalyze: canAnalyze,
                startAnalysis: startAnalysis,
                stopAnalysis: stopAnalysis,
                openSafeCleanup: openSafeCleanup
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text("统计已识别来源的文件分配空间，不代表整个磁盘的已用空间。"))
                    .foregroundStyle(.secondary)
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if skippedEntryCount > 0 {
                    Label(L10n.text("部分位置无法读取，容量可能偏低"), systemImage: "exclamationmark.shield")
                        .foregroundStyle(.orange)
                }
                if conflictBytes > 0 {
                    Label(L10n.format("%@ 共享占用无法唯一归属，已在总量中计入一次。", AgentStorageSizeFormatter.string(conflictBytes)),
                          systemImage: "square.on.square")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)

            if availableWidth >= StorageMapWideHero.minimumWidth {
                StorageMapWideHero(
                    scope: $scope,
                    sources: data.sources,
                    volumes: volumes,
                    sourceTitles: data.sourceTitles,
                    openSource: openSource
                )
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    StorageSourceMapSection(
                        scope: $scope,
                        sources: data.sources,
                        openSource: openSource
                    )

                    StorageVolumeGrid(
                        volumes: volumes,
                        sourceTitles: data.sourceTitles
                    )
                }
            }

            StorageSourceTable(
                availableWidth: availableWidth,
                sources: data.sources,
                openAvailability: openAvailability,
                unavailableMessage: unavailableMessage,
                canReanalyze: canReanalyze,
                openSource: openSource,
                reanalyze: reanalyze
            )
        }
    }
}

private struct StorageMapWideHero: View {
    static let minimumWidth: CGFloat = Metrics.sourceColumnMinimumWidth
        + Metrics.columnSpacing + Metrics.volumeColumnMinimumWidth

    private enum Metrics {
        static let sourceColumnMinimumWidth: CGFloat = 440
        static let sourceColumnComfortableWidth: CGFloat = 520
        static let volumeColumnMinimumWidth: CGFloat = 288
        static let volumeColumnPreferredWidth: CGFloat = 320
        static let columnSpacing: CGFloat = 16
    }

    @Binding var scope: StorageMapScope

    let sources: [StorageMapDashboardSource]
    let volumes: [StorageVolumeSnapshot]
    let sourceTitles: [StorageSourceID: String]
    let openSource: (StorageSourceID) -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StorageSourceScopeControl(scope: $scope)

            StorageMapWideColumnLayout(
                sourceColumnMinimumWidth: Metrics.sourceColumnMinimumWidth,
                sourceColumnComfortableWidth: Metrics.sourceColumnComfortableWidth,
                volumeColumnMinimumWidth: Metrics.volumeColumnMinimumWidth,
                volumeColumnPreferredWidth: Metrics.volumeColumnPreferredWidth,
                columnSpacing: Metrics.columnSpacing
            ) {
                StorageSourceCountHeader(sourceCount: sources.count)
                    .frame(height: 20)

                StorageVolumeSectionHeader(volumeCount: volumes.count)
                    .frame(height: 20)
            }
            .frame(height: 20)

            StorageMapWideColumnLayout(
                sourceColumnMinimumWidth: Metrics.sourceColumnMinimumWidth,
                sourceColumnComfortableWidth: Metrics.sourceColumnComfortableWidth,
                volumeColumnMinimumWidth: Metrics.volumeColumnMinimumWidth,
                volumeColumnPreferredWidth: Metrics.volumeColumnPreferredWidth,
                columnSpacing: Metrics.columnSpacing
            ) {
                StorageSourceMapContent(
                    sources: sources,
                    openSource: openSource,
                    contentHeight: 422
                )
                .clipped()

                StorageVolumePane(
                    volumes: volumes,
                    sourceTitles: sourceTitles
                )
            }
            .frame(height: 422)
        }
        .frame(maxWidth: .infinity, minHeight: 498, maxHeight: 498, alignment: .topLeading)
    }
}

private struct StorageMapWideColumnLayout: Layout {
    let sourceColumnMinimumWidth: CGFloat
    let sourceColumnComfortableWidth: CGFloat
    let volumeColumnMinimumWidth: CGFloat
    let volumeColumnPreferredWidth: CGFloat
    let columnSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let minimumWidth = sourceColumnMinimumWidth
            + columnSpacing
            + volumeColumnMinimumWidth
        return CGSize(
            width: max(minimumWidth, proposal.width ?? minimumWidth),
            height: proposal.height ?? 390
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let sourceMap = subviews.first else { return }

        let volumeColumnWidth = min(
            volumeColumnPreferredWidth,
            max(
                volumeColumnMinimumWidth,
                bounds.width - columnSpacing - sourceColumnComfortableWidth
            )
        )
        let sourceWidth = max(0, bounds.width - columnSpacing - volumeColumnWidth)
        sourceMap.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: sourceWidth, height: bounds.height)
        )

        guard subviews.count > 1 else { return }
        let volumeX = bounds.minX + sourceWidth + columnSpacing
        subviews[1].place(
            at: CGPoint(x: volumeX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: volumeColumnWidth, height: bounds.height)
        )
    }
}

private struct StorageMapDashboardData {
    let sources: [StorageMapDashboardSource]
    let sourceTitles: [StorageSourceID: String]

    init(
        items: [StorageMapDashboardItem],
        volumes: [StorageVolumeSnapshot],
        safeCleanupBytesBySource: [StorageSourceID: UInt64]
    ) {
        sourceTitles = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.title) })

        var allocationsBySource: [StorageSourceID: [StorageMapVolumeAllocation]] = [:]
        for volume in volumes {
            for usage in volume.sourceUsages where usage.allocatedBytes > 0 {
                allocationsBySource[usage.sourceID, default: []].append(
                    StorageMapVolumeAllocation(
                        volumeID: volume.id,
                        volumeName: volume.name,
                        allocatedBytes: usage.allocatedBytes
                    )
                )
            }
        }

        sources = items.map { item in
            StorageMapDashboardSource(
                item: item,
                safeCleanupBytes: safeCleanupBytesBySource[item.id] ?? 0,
                volumeAllocations: (allocationsBySource[item.id] ?? []).sorted {
                    if $0.allocatedBytes != $1.allocatedBytes {
                        return $0.allocatedBytes > $1.allocatedBytes
                    }
                    return $0.volumeName.localizedStandardCompare($1.volumeName) == .orderedAscending
                }
            )
        }
    }
}

private struct StorageMapDashboardSource: Identifiable {
    let item: StorageMapDashboardItem
    let safeCleanupBytes: UInt64
    let volumeAllocations: [StorageMapVolumeAllocation]

    var id: StorageSourceID { item.id }
    var title: String { item.title }
    var family: StorageSourceFamily { item.family }
    var bytes: UInt64 { item.displayBytes }
}

/// The dashboard is refreshed while a scan is running. Keep this projection
/// deliberately small so the live view tree does not retain every source's
/// resource tree and other detail-only data.
struct StorageMapDashboardItem: Identifiable {
    let id: StorageSourceID
    let title: String
    let family: StorageSourceFamily
    let symbol: String
    let activity: StorageSourceActivityPresentation
    let displayBytes: UInt64

    init(
        candidate: StorageSourceCandidate,
        activity: StorageSourceActivityPresentation,
        displayBytes: UInt64
    ) {
        id = candidate.id
        title = L10n.text(candidate.descriptor.title)
        family = candidate.descriptor.family
        symbol = candidate.descriptor.symbol
        self.activity = activity
        self.displayBytes = displayBytes
    }
}

private struct StorageMapVolumeAllocation: Identifiable {
    let volumeID: String
    let volumeName: String
    let allocatedBytes: UInt64

    var id: String { volumeID }
}

/// All three header elements exist once. Measure their actual widths before
/// placing them, including both actions and the selected language's title.
private struct StorageMapHeaderLayout: Layout {
    struct Cache {
        var title: CGSize
        var metrics: CGSize
        var actions: CGSize
        var minimumTitleWidth: CGFloat
    }

    func makeCache(subviews: Subviews) -> Cache {
        let titleWidth = ceil((L10n.text("空间地图") as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold)
        ]).width) + 2
        let preferredTitleWidth = max(210, titleWidth)
        return Cache(
            title: subviews[0].sizeThatFits(.init(width: preferredTitleWidth, height: nil)),
            metrics: subviews[1].sizeThatFits(.unspecified),
            actions: subviews[2].sizeThatFits(.unspecified),
            minimumTitleWidth: titleWidth
        )
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let width = proposal.width ?? cache.title.width + cache.metrics.width + cache.actions.width + 48
        let frames = frames(width: width, cache: cache)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        for (index, frame) in frames(width: bounds.width, cache: cache).enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func frames(width: CGFloat, cache: Cache) -> [CGRect] {
        let title = cache.title
        let metrics = cache.metrics
        let actions = cache.actions
        if title.width + metrics.width + actions.width + 48 <= width {
            let height = max(title.height, max(metrics.height, actions.height))
            return [
                CGRect(x: 0, y: (height - title.height) / 2, width: title.width, height: title.height),
                CGRect(x: title.width + 24, y: (height - metrics.height) / 2,
                       width: metrics.width, height: metrics.height),
                CGRect(x: width - actions.width, y: (height - actions.height) / 2,
                       width: actions.width, height: actions.height)
            ]
        }
        if cache.minimumTitleWidth + actions.width + 16 <= width {
            let topHeight = max(title.height, actions.height)
            return [
                CGRect(x: 0, y: 0, width: min(title.width, width - actions.width - 16), height: title.height),
                CGRect(x: 0, y: topHeight + 16, width: metrics.width, height: metrics.height),
                CGRect(x: width - actions.width, y: 0, width: actions.width, height: actions.height)
            ]
        }
        return [
            CGRect(x: 0, y: 0, width: width, height: title.height),
            CGRect(x: 0, y: title.height + 16, width: metrics.width, height: metrics.height),
            CGRect(x: 0, y: title.height + metrics.height + 32, width: actions.width, height: actions.height)
        ]
    }
}

private struct StorageMapDashboardHeader: View {
    let analyzedBytes: UInt64?
    let entryCount: Int?
    let volumeCount: Int
    let scannedAt: Date?
    let analysisActivity: StorageMapAnalysisActivity?
    let safeCleanupBytes: UInt64
    let isPresentingLiveResults: Bool
    let isAnalysisRunning: Bool
    let isStopping: Bool
    let canAnalyze: Bool
    let startAnalysis: () -> Void
    let stopAnalysis: () -> Void
    let openSafeCleanup: () -> Void

    var body: some View {
        StorageMapHeaderLayout {
            titleBlock
            summaryMetrics
            actionGroup
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("空间地图"))
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .modifier(StorageMapTextShimmer(isActive: analysisActivity != nil))
            }
            .frame(height: 16, alignment: .leading)
            .help(activityDescription)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(activityDescription)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryMetrics: some View {
        HStack(spacing: 0) {
            StorageMapHeaderMetric(
                value: analyzedBytes.map(AgentStorageSizeFormatter.string) ?? "—",
                label: isPresentingLiveResults ? L10n.text("扫描中占用（待核对）") : L10n.text("已分析空间"),
                width: 148
            )
            metricDivider
            StorageMapHeaderMetric(
                value: entryCount.map { L10n.number($0) } ?? "—",
                label: L10n.text("文件系统条目"),
                width: 126
            )
            .help(L10n.text("按文件身份去重，包含文件、目录和符号链接。"))
            metricDivider
            StorageMapHeaderMetric(
                value: volumeCount > 0 ? L10n.number(volumeCount) : "—",
                label: L10n.text("磁盘卷"),
                width: 60
            )
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.58))
            .frame(width: 1, height: 38)
            .padding(.horizontal, 18)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var actionGroup: some View {
        HStack(spacing: 10) {
            Button(action: isAnalysisRunning ? stopAnalysis : startAnalysis) {
                HStack(spacing: 8) {
                    if isAnalysisRunning {
                        Image(systemName: isStopping ? "ellipsis" : "stop.fill")
                            .font(.system(size: isStopping ? 12 : 9, weight: .medium))
                            .frame(width: 22, height: 22)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 22, height: 22)
                    }
                    Text(L10n.text(isStopping ? "正在停止" : (isAnalysisRunning ? "停止分析" : "重新分析")))
                        .lineLimit(1)
                }
                .font(.callout.weight(.medium))
                .contentShape(Rectangle())
            }
            .buttonStyle(StorageMapHeaderActionButtonStyle(kind: isAnalysisRunning ? .analyzing : .standard))
            .help(L10n.text(isStopping ? "正在停止" : (isAnalysisRunning ? "停止分析" : "重新分析空间地图")))
            .accessibilityIdentifier("storage-map-dashboard-reanalyze")
            .disabled(!canAnalyze || isStopping)

            if safeCleanupBytes > 0 {
                Button(action: openSafeCleanup) {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 18, weight: .semibold))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.text("可清理项目占用"))
                                .font(.caption.weight(.medium))
                            Text(AgentStorageSizeFormatter.string(safeCleanupBytes))
                                .font(.system(.callout, design: .rounded, weight: .semibold))
                                .monospacedDigit()
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(StorageMapHeaderActionButtonStyle(kind: .cleanup))
                .help(L10n.text("查看可安全清理的缓存"))
                .accessibilityIdentifier("storage-map-safe-cleanup-scope")
            }
        }
    }

    private var detailText: String {
        if isStopping { return L10n.text("正在停止") }
        if let activity = analysisActivity {
            if let source = activity.rows.first {
                return L10n.format("%@ · %@", source.title, source.phaseTitle)
            }
            return activity.title
        }
        if isAnalysisRunning { return L10n.text("正在分析") }
        if let scannedAt {
            return L10n.format(
                "更新于 %@",
                L10n.date(scannedAt, date: .omitted, time: .shortened)
            )
        }
        return L10n.text("等待你开始只读分析")
    }

    private var activityDescription: String {
        guard let activity = analysisActivity else { return detailText }
        return ([activity.title, activity.summary].compactMap { $0 }
            + activity.rows.map { $0.title + " · " + $0.detail }).joined(separator: "\n")
    }
}

private enum StorageMapHeaderActionButtonKind {
    case standard
    case analyzing
    case cleanup
}

private struct StorageMapHeaderActionButtonStyle: ButtonStyle {
    let kind: StorageMapHeaderActionButtonKind

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        StorageMapHeaderActionButtonBody(
            label: configuration.label,
            kind: kind,
            isEnabled: isEnabled,
            isPressed: configuration.isPressed
        )
    }
}

private struct StorageMapHeaderActionButtonBody<Label: View>: View {
    let label: Label
    let kind: StorageMapHeaderActionButtonKind
    let isEnabled: Bool
    let isPressed: Bool

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        label
            .modifier(StorageMapTextShimmer(isActive: kind == .analyzing))
            .frame(width: 166, height: 52)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor, in: buttonShape)
            .background {
                if kind == .analyzing {
                    buttonShape.fill(InstrumentDesign.Palette.canvasRaised)
                }
            }
            .overlay {
                buttonShape.strokeBorder(borderColor, lineWidth: isHovering ? 1 : 0.75)
            }
            .overlay {
                if kind == .analyzing, !reduceMotion {
                    StorageMapLightSweep(strength: colorScheme == .dark ? 0.1 : 0.055)
                        .clipShape(buttonShape)
                }
            }
            .contentShape(buttonShape)
            .opacity(isEnabled ? 1 : 0.46)
            .scaleEffect(isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.1), value: isPressed)
            .animation(.easeOut(duration: 0.14), value: isHovering)
            .onHover { isHovering = $0 }
    }

    private var buttonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: InstrumentDesign.Radius.panel)
    }

    private var foregroundColor: Color {
        switch kind {
        case .standard: .primary
        case .analyzing: .primary
        case .cleanup: InstrumentDesign.ColorRole.cleanup
        }
    }

    private var backgroundColor: Color {
        switch kind {
        case .standard:
            if isPressed { return Color.primary.opacity(0.14) }
            if isHovering { return Color.primary.opacity(0.11) }
            return Color(nsColor: .controlBackgroundColor).opacity(0.92)
        case .analyzing:
            return Color.primary.opacity(isPressed ? 0.1 : (isHovering ? 0.065 : 0.025))
        case .cleanup:
            if isPressed { return InstrumentDesign.ColorRole.cleanup.opacity(0.24) }
            if isHovering { return InstrumentDesign.ColorRole.cleanup.opacity(0.2) }
            return InstrumentDesign.ColorRole.cleanup.opacity(0.14)
        }
    }

    private var borderColor: Color {
        switch kind {
        case .standard:
            return isHovering
                ? Color.primary.opacity(0.3)
                : Color(nsColor: .separatorColor).opacity(0.9)
        case .analyzing:
            return Color.primary.opacity(isHovering ? 0.28 : (colorScheme == .dark ? 0.18 : 0.14))
        case .cleanup:
            return InstrumentDesign.ColorRole.cleanup.opacity(isHovering ? 0.58 : 0.32)
        }
    }
}

private struct StorageMapHeaderMetric: View {
    let value: String
    let label: String
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            StorageMapNumberText(value, size: 17, weight: .medium, rounded: true)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .help(label)
        .accessibilityElement(children: .combine)
    }
}

private struct StorageSourceMapSection: View {
    @Binding var scope: StorageMapScope

    let sources: [StorageMapDashboardSource]
    let openSource: (StorageSourceID) -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StorageSourceMapHeader(
                scope: $scope,
                sourceCount: sources.count
            )
            StorageSourceMapContent(
                sources: sources,
                openSource: openSource
            )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct StorageSourceMapHeader: View {
    @Binding var scope: StorageMapScope

    let sourceCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sourceCountLabel
            scopeTabs
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scopeTabs: some View {
        StorageSourceScopeControl(scope: $scope)
    }

    private var sourceCountLabel: some View {
        Text(sourceCount > 5
            ? L10n.format("展示前 5 个来源 · 共 %d 个", sourceCount)
            : L10n.format("%d 个来源", sourceCount))
            .help(L10n.text("卡片面积兼顾文字可读性；占比以标注的百分比为准。"))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

private struct StorageSourceScopeControl: View {
    @Binding var scope: StorageMapScope

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= 640 {
                GlassSegmentedControl("来源分类", selection: $scope) {
                    scopeOptions
                }
            } else {
                Picker(L10n.text("来源分类"), selection: $scope) {
                    scopeOptions
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: 720)
        .frame(height: 32)
    }

    private var scopeOptions: some View {
        ForEach(StorageMapScope.allCases) { item in
            Text(item.title)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .tag(item)
        }
    }
}

private struct StorageSourceCountHeader: View {
    let sourceCount: Int

    var body: some View {
        Text(sourceCount > 5
            ? L10n.format("展示前 5 个来源 · 共 %d 个", sourceCount)
            : L10n.format("%d 个来源", sourceCount))
            .help(L10n.text("卡片面积兼顾文字可读性；占比以标注的百分比为准。"))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

private struct StorageSourceMapContent: View {
    let sources: [StorageMapDashboardSource]
    let openSource: (StorageSourceID) -> String?
    var contentHeight: CGFloat = 390

    private var visibleSources: [StorageMapDashboardSource] {
        Array(sources.prefix(5))
    }

    private var totalBytes: UInt64 {
        sources.reduce(0) { partial, source in
            let sum = partial.addingReportingOverflow(source.bytes)
            return sum.overflow ? .max : sum.partialValue
        }
    }

    var body: some View {
        Group {
            if visibleSources.isEmpty {
                ContentUnavailableView {
                    Label(
                        L10n.text("此分类暂无来源"),
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                } description: {
                    Text(L10n.text("切换到其他来源分类查看已发现的应用与工具。"))
                }
            } else {
                StorageSourceMapLayout(spacing: 8) {
                    ForEach(Array(visibleSources.enumerated()), id: \.element.id) { index, source in
                        StorageSourceMapCard(
                            source: source,
                            totalBytes: totalBytes,
                            emphasized: index < 2,
                            openSource: openSource
                        )
                        .layoutValue(
                            key: StorageSourceMapWeightKey.self,
                            value: Double(max(1, source.bytes))
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: contentHeight, maxHeight: contentHeight)
    }
}

private struct StorageSourceMapCard: View {
    let source: StorageMapDashboardSource
    let totalBytes: UInt64
    let emphasized: Bool
    let openSource: (StorageSourceID) -> String?

    @State private var isHovering = false
    @State private var isOpening = false
    @State private var accessFeedback: String?
    @State private var openTask: Task<Void, Never>?
    @State private var feedbackTask: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: requestOpen) {
            VStack(alignment: .leading, spacing: emphasized ? 15 : 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(source.family.color)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(source.title)
                        .font(emphasized ? .body.weight(.medium) : .callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if isOpening {
                        ProgressView()
                            .controlSize(.mini)
                            .allowsHitTesting(false)
                    }
                }

                if let accessFeedback {
                    Label(accessFeedback, systemImage: "exclamationmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else {
                    StorageMapNumberText(
                        AgentStorageSizeFormatter.string(source.bytes),
                        size: emphasized ? 34 : 25,
                        weight: .light
                    )

                    Text(shareText)
                        .font(emphasized ? .title3 : .callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                GeometryReader { proxy in
                    HStack(alignment: .bottom, spacing: 10) {
                        footerLabel
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if proxy.size.width >= 180 {
                            StorageSourceBrandIcon(
                                sourceID: source.id,
                                fallbackSymbol: source.item.symbol
                            )
                            .scaleEffect(emphasized ? 1.2 : 1)
                            .opacity(0.72)
                            .accessibilityHidden(true)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
                }
                // Preserve the icon's original footprint when a narrow card prioritizes its status.
                .frame(height: 40, alignment: .bottomLeading)
            }
            .padding(emphasized ? 18 : 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: InstrumentDesign.Radius.panel)
                    .fill(areaFill)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay {
            RoundedRectangle(cornerRadius: InstrumentDesign.Radius.panel)
                .strokeBorder(
                    isHovering
                        ? Color.primary.opacity(0.3)
                        : Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.11),
                    lineWidth: isHovering ? 1.1 : 0.7
                )
                .allowsHitTesting(false)
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .onDisappear {
            openTask?.cancel()
            feedbackTask?.cancel()
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(L10n.text("查看专属分析"))
    }

    @ViewBuilder
    private var footerLabel: some View {
        if source.item.activity.state == .active {
            Text(source.item.activity.phaseTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .modifier(StorageMapTextShimmer(isActive: true))
                .help(source.item.activity.workDetail)
        } else if source.safeCleanupBytes > 0 {
            Label(
                AgentStorageSizeFormatter.string(source.safeCleanupBytes),
                systemImage: "checkmark.shield.fill"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(InstrumentDesign.ColorRole.cleanup)
        } else {
            Text(source.item.activity.phaseTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var shareText: String {
        guard totalBytes > 0 else { return L10n.percent(0) }
        return L10n.percent(Double(source.bytes) / Double(totalBytes))
    }

    private var areaFill: Color {
        let baseOpacity: Double
        if colorScheme == .dark {
            baseOpacity = emphasized ? 0.12 : 0.095
            return Color.white.opacity(baseOpacity + (isHovering ? 0.025 : 0))
        }
        baseOpacity = emphasized ? 0.075 : 0.055
        return Color.black.opacity(baseOpacity + (isHovering ? 0.018 : 0))
    }

    private func requestOpen() {
        guard !isOpening else { return }
        isOpening = true
        accessFeedback = nil
        openTask?.cancel()
        openTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            let feedback = openSource(source.id)
            isOpening = false
            if let feedback { presentFeedback(feedback) }
        }
    }

    private func presentFeedback(_ message: String) {
        accessFeedback = message
        feedbackTask?.cancel()
        feedbackTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            accessFeedback = nil
        }
    }
}

private struct StorageSourceMapWeightKey: LayoutValueKey {
    static let defaultValue: Double = 1
}

private struct StorageSourceMapLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        CGSize(width: proposal.width ?? 620, height: proposal.height ?? 390)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let weights = subviews.map { max(1, $0[StorageSourceMapWeightKey.self]) }
        let frames = frames(in: bounds, weights: weights)
        for (index, subview) in subviews.enumerated() where index < frames.count {
            subview.place(
                at: frames[index].origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(frames[index].size)
            )
        }
    }

    private func frames(in bounds: CGRect, weights: [Double]) -> [CGRect] {
        switch weights.count {
        case 0:
            return []
        case 1:
            return [bounds]
        case 2:
            return horizontalFrames(in: bounds, weights: weights, minimumShare: 0.34, minimumLength: 180)
        case 3:
            let leadingShare = clampedShare(
                weights[0] / weights.reduce(0, +),
                minimum: 0.46,
                maximum: 0.62
            )
            let leadingWidth = (bounds.width - spacing) * leadingShare
            let trailingWidth = bounds.width - spacing - leadingWidth
            let leading = CGRect(x: bounds.minX, y: bounds.minY, width: leadingWidth, height: bounds.height)
            let trailingBounds = CGRect(
                x: leading.maxX + spacing,
                y: bounds.minY,
                width: trailingWidth,
                height: bounds.height
            )
            return [leading] + verticalFrames(in: trailingBounds, weights: Array(weights.dropFirst()), minimumShare: 0.34)
        case 4:
            let rowWeights = [weights[0] + weights[1], weights[2] + weights[3]]
            let rows = verticalFrames(in: bounds, weights: rowWeights, minimumShare: 0.40)
            return horizontalFrames(in: rows[0], weights: Array(weights[0...1]), minimumShare: 0.34, minimumLength: 180)
                + horizontalFrames(in: rows[1], weights: Array(weights[2...3]), minimumShare: 0.34, minimumLength: 180)
        default:
            let topWeight = weights[0] + weights[1]
            let bottomWeight = weights[2...4].reduce(0, +)
            let topShare = clampedShare(
                topWeight / (topWeight + bottomWeight),
                minimum: 0.56,
                maximum: 0.68
            )
            let availableHeight = max(0, bounds.height - spacing)
            let minimumBottomHeight = min(180, availableHeight)
            let topHeight = min(
                availableHeight * topShare,
                max(0, availableHeight - minimumBottomHeight)
            )
            let topBounds = CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: bounds.width,
                height: topHeight
            )
            let bottomBounds = CGRect(
                x: bounds.minX,
                y: topBounds.maxY + spacing,
                width: bounds.width,
                height: bounds.height - spacing - topHeight
            )
            return horizontalFrames(in: topBounds, weights: Array(weights[0...1]), minimumShare: 0.34, minimumLength: 180)
                + horizontalFrames(
                    in: bottomBounds,
                    weights: Array(weights[2...4]),
                    minimumShare: 0,
                    minimumLength: 124
                )
        }
    }

    private func horizontalFrames(
        in bounds: CGRect,
        weights: [Double],
        minimumShare: Double,
        minimumLength: CGFloat = 0
    ) -> [CGRect] {
        let widths = weightedLengths(
            available: bounds.width,
            weights: weights,
            minimumShare: minimumShare,
            minimumLength: minimumLength
        )
        var x = bounds.minX
        return widths.map { width in
            defer { x += width + spacing }
            return CGRect(x: x, y: bounds.minY, width: width, height: bounds.height)
        }
    }

    private func verticalFrames(
        in bounds: CGRect,
        weights: [Double],
        minimumShare: Double
    ) -> [CGRect] {
        let heights = weightedLengths(
            available: bounds.height,
            weights: weights,
            minimumShare: minimumShare
        )
        var y = bounds.minY
        return heights.map { height in
            defer { y += height + spacing }
            return CGRect(x: bounds.minX, y: y, width: bounds.width, height: height)
        }
    }

    private func weightedLengths(
        available: CGFloat,
        weights: [Double],
        minimumShare: Double,
        minimumLength: CGFloat = 0
    ) -> [CGFloat] {
        guard !weights.isEmpty else { return [] }
        let contentLength = max(0, available - spacing * CGFloat(weights.count - 1))
        let totalWeight = max(1, weights.reduce(0, +))
        let shares = weights.map { $0 / totalWeight }
        let floorShare = min(minimumShare, 1 / Double(weights.count))
        let floored = shares.map { max(floorShare, $0) }
        let normalizedTotal = floored.reduce(0, +)
        var lengths = floored.map { contentLength * CGFloat($0 / normalizedTotal) }
        let readableMinimum = min(minimumLength, contentLength / CGFloat(weights.count))
        guard readableMinimum > 0 else { return lengths }

        var fixedIndices = Set<Int>()
        while true {
            let newlyFixed = lengths.indices.filter {
                !fixedIndices.contains($0) && lengths[$0] < readableMinimum
            }
            guard !newlyFixed.isEmpty else { break }
            fixedIndices.formUnion(newlyFixed)

            let remainingLength = max(
                0,
                contentLength - readableMinimum * CGFloat(fixedIndices.count)
            )
            let flexibleIndices = lengths.indices.filter { !fixedIndices.contains($0) }
            let flexibleWeight = max(
                0.000_001,
                flexibleIndices.reduce(0) { $0 + floored[$1] }
            )
            for index in lengths.indices {
                lengths[index] = fixedIndices.contains(index)
                    ? readableMinimum
                    : remainingLength * CGFloat(floored[index] / flexibleWeight)
            }
        }
        return lengths
    }

    private func clampedShare(_ value: Double, minimum: Double, maximum: Double) -> CGFloat {
        CGFloat(min(maximum, max(minimum, value)))
    }
}

private struct StorageVolumeSectionHeader: View {
    let volumeCount: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.text("磁盘卷"))
                .font(.callout.weight(.semibold))
            Spacer(minLength: 8)
            Text(L10n.format("%d 块磁盘", volumeCount))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct StorageVolumePane: View {
    let volumes: [StorageVolumeSnapshot]
    let sourceTitles: [StorageSourceID: String]

    var body: some View {
        GeometryReader { proxy in
            volumeContent(size: proxy.size)
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height,
                    alignment: .topLeading
                )
        }
    }

    @ViewBuilder
    private func volumeContent(size: CGSize) -> some View {
        switch volumes.count {
        case 0:
            StorageVolumeUnavailableCard(fillsAvailableHeight: true)
        case 1:
            StorageDashboardVolumeCard(
                volume: volumes[0],
                sourceTitles: sourceTitles,
                minimumHeight: 0,
                fillsAvailableHeight: true,
                isExpanded: true
            )
        case 2:
            let spacing: CGFloat = 12
            let cardHeight = max(0, (size.height - spacing) / 2)
            VStack(spacing: spacing) {
                ForEach(volumes) { volume in
                    StorageDashboardVolumeCard(
                        volume: volume,
                        sourceTitles: sourceTitles,
                        minimumHeight: 0,
                        fillsAvailableHeight: true
                    )
                    .frame(height: cardHeight)
                }
            }
        default:
            ScrollView(.vertical) {
                LazyVStack(spacing: 12) {
                    ForEach(volumes) { volume in
                        StorageDashboardVolumeCard(
                            volume: volume,
                            sourceTitles: sourceTitles
                        )
                    }
                }
            }
            .scrollIndicators(.visible)
        }
    }
}

private struct StorageVolumeUnavailableCard: View {
    var fillsAvailableHeight = false

    var body: some View {
        Group {
            if fillsAvailableHeight {
                GeometryReader { proxy in
                    unavailableLabel
                        .frame(
                            width: proxy.size.width,
                            height: proxy.size.height
                        )
                        .glassSurface(padding: 16)
                }
            } else {
                unavailableLabel
                    .frame(maxWidth: .infinity, minHeight: 188)
                    .glassSurface(padding: 16)
            }
        }
    }

    private var unavailableLabel: some View {
        Label(
            L10n.text("刷新分析以生成磁盘级空间构成"),
            systemImage: "externaldrive.badge.questionmark"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

private struct StorageVolumeGrid: View {
    let volumes: [StorageVolumeSnapshot]
    let sourceTitles: [StorageSourceID: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("磁盘卷"))
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                Text(L10n.format("%d 块磁盘", volumes.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if volumes.isEmpty {
                Label(
                    L10n.text("刷新分析以生成磁盘级空间构成"),
                    systemImage: "externaldrive.badge.questionmark"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
                .glassSurface(padding: 16)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 300), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(volumes) { volume in
                        StorageDashboardVolumeCard(
                            volume: volume,
                            sourceTitles: sourceTitles
                        )
                    }
                }
            }
        }
    }
}

private struct StorageDashboardVolumeCard: View {
    let volume: StorageVolumeSnapshot
    let sourceTitles: [StorageSourceID: String]
    var minimumHeight: CGFloat = 190
    var fillsAvailableHeight = false
    var isExpanded = false

    var body: some View {
        cardSurface
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var cardSurface: some View {
        if fillsAvailableHeight {
            GeometryReader { proxy in
                cardContent
                    .padding(16)
                    .frame(
                        width: proxy.size.width,
                        height: proxy.size.height,
                        alignment: .topLeading
                    )
                    .glassSurface(padding: 0)
            }
        } else {
            cardContent
                .padding(16)
                .frame(
                    minWidth: 0,
                    maxWidth: .infinity,
                    minHeight: minimumHeight,
                    alignment: .topLeading
                )
                .glassSurface(padding: 0)
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 13) {
            volumeHeader

            if isExpanded {
                Spacer(minLength: 0)
            }

            volumeSummary(diameter: isExpanded ? 112 : 84)

            if isExpanded {
                Spacer(minLength: 0)
            }

            StorageDashboardCapacityBar(
                volume: volume,
                sourceTitles: sourceTitles
            )
        }
    }

    private var volumeHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: volume.mountPath == "/" ? "internaldrive.fill" : "externaldrive.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(volume.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(volume.mountPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func volumeSummary(diameter: CGFloat) -> some View {
        HStack(spacing: isExpanded ? 24 : 18) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.17), lineWidth: isExpanded ? 15 : 13)
                Circle()
                    .trim(from: 0, to: usedShare)
                    .stroke(
                        InstrumentDesign.ColorRole.read,
                        style: StrokeStyle(
                            lineWidth: isExpanded ? 15 : 13,
                            lineCap: .butt
                        )
                    )
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(L10n.percent(Double(usedShare)))
                        .font(.caption.weight(.semibold).monospacedDigit())
                    Text(L10n.text("已用"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: diameter, height: diameter)
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: isExpanded ? 12 : 8) {
                volumeFact(
                    title: L10n.text("已用"),
                    value: AgentStorageSizeFormatter.string(volume.usedBytes)
                )
                Divider()
                volumeFact(
                    title: L10n.text("可用空间"),
                    value: AgentStorageSizeFormatter.string(volume.availableCapacity)
                )
                .help(L10n.text("系统报告的当前可用空间；共享块、快照和可清除空间会影响实际释放量。"))
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var usedShare: CGFloat {
        guard volume.totalCapacity > 0 else { return 0 }
        return min(1, max(0, CGFloat(Double(volume.usedBytes) / Double(volume.totalCapacity))))
    }

    private func volumeFact(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(.caption, design: .rounded, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StorageDashboardCapacityBar: View {
    let volume: StorageVolumeSnapshot
    let sourceTitles: [StorageSourceID: String]

    var body: some View {
        GeometryReader { proxy in
            let currentSegments = segments
            let spacing: CGFloat = 3
            let widths = segmentWidths(
                availableWidth: proxy.size.width,
                segments: currentSegments,
                spacing: spacing
            )

            HStack(spacing: spacing) {
                ForEach(Array(currentSegments.enumerated()), id: \.element.id) { index, segment in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(segment.color)
                        .frame(width: widths[index])
                        .help(L10n.format(
                            "%@ · %@",
                            segment.title,
                            AgentStorageSizeFormatter.string(segment.bytes)
                        ))
                }
            }
            .frame(
                width: proxy.size.width,
                height: proxy.size.height,
                alignment: .leading
            )
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: 15)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("磁盘空间使用构成"))
        .accessibilityValue(L10n.percent(Double(usedShare)))
    }

    private var segments: [StorageDashboardCapacitySegment] {
        let total = max(1, volume.totalCapacity)
        let allocationScale = volume.analyzedBytes > volume.usedBytes && volume.analyzedBytes > 0
            ? Double(volume.usedBytes) / Double(volume.analyzedBytes) : 1
        var values = volume.sourceUsages.map { usage in
            StorageDashboardCapacitySegment(
                id: usage.sourceID.rawValue,
                title: sourceTitles[usage.sourceID] ?? usage.sourceID.rawValue,
                bytes: usage.allocatedBytes,
                share: CGFloat(Double(usage.allocatedBytes) * allocationScale / Double(total)),
                color: storageDashboardSourceColor(usage.sourceID)
            )
        }
        if volume.otherBytes > 0 {
            values.append(StorageDashboardCapacitySegment(
                id: "other",
                title: L10n.text("其它"),
                bytes: volume.otherBytes,
                share: CGFloat(Double(volume.otherBytes) / Double(total)),
                color: Color.secondary.opacity(0.48)
            ))
        }
        if volume.availableCapacity > 0 {
            values.append(StorageDashboardCapacitySegment(
                id: "available",
                title: L10n.text("可用空间"),
                bytes: volume.availableCapacity,
                share: CGFloat(Double(volume.availableCapacity) / Double(total)),
                color: Color.secondary.opacity(0.16)
            ))
        }
        return values.filter { $0.share > 0 }
    }

    private var usedShare: CGFloat {
        guard volume.totalCapacity > 0 else { return 0 }
        return min(1, max(0, CGFloat(Double(volume.usedBytes) / Double(volume.totalCapacity))))
    }

    private func segmentWidths(
        availableWidth: CGFloat,
        segments: [StorageDashboardCapacitySegment],
        spacing: CGFloat
    ) -> [CGFloat] {
        guard !segments.isEmpty else { return [] }

        let totalSpacing = spacing * CGFloat(max(0, segments.count - 1))
        let contentWidth = max(0, availableWidth - totalSpacing)
        let shareTotal = max(0.000_001, segments.reduce(0) { $0 + $1.share })
        return segments.map { contentWidth * ($0.share / shareTotal) }
    }
}

private struct StorageDashboardCapacitySegment: Identifiable {
    let id: String
    let title: String
    let bytes: UInt64
    let share: CGFloat
    let color: Color
}

/// Header and rows share one column contract and one breakpoint. Longer
/// translations expand the relevant column before the table chooses its mode.
private struct StorageSourceTableColumns {
    let identity = Self.width("来源", minimum: 220)
    let family = Self.width("来源分类", minimum: 130)
    let size = Self.width("已分析空间", minimum: 105)
    let volumes = Self.width("磁盘卷", minimum: 230)
    let cleanup = Self.width("可安全清理", minimum: 110)
    let status = Self.width("状态", minimum: 105)

    var requiredWidth: CGFloat {
        identity + family + size + volumes + cleanup + status
            + 5 * 16 + 10 + 34 + 2 * 14
    }

    private static func width(_ key: String, minimum: CGFloat) -> CGFloat {
        max(minimum, ceil((L10n.text(key) as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 11)
        ]).width) + 4)
    }
}

private struct StorageSourceTable: View {
    let availableWidth: CGFloat
    let sources: [StorageMapDashboardSource]
    let openAvailability: (StorageSourceID) -> StorageSourceResultAccess
    let unavailableMessage: (StorageSourceID, StorageSourceResultAccess) -> String
    let canReanalyze: (StorageSourceID) -> Bool
    let openSource: (StorageSourceID) -> String?
    let reanalyze: (StorageSourceID) -> Void

    var body: some View {
        let columns = StorageSourceTableColumns()
        let usesWideLayout = availableWidth >= columns.requiredWidth

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("来源"))
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                Text(L10n.format("%d 个来源", sources.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                StorageSourceTableHeader(columns: columns, usesWideLayout: usesWideLayout)
                Divider()
                if sources.isEmpty {
                    ContentUnavailableView {
                        Label(
                            L10n.text("此分类暂无来源"),
                            systemImage: "line.3.horizontal.decrease.circle"
                        )
                    } description: {
                        Text(L10n.text("切换到其他来源分类查看已发现的应用与工具。"))
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                            if index > 0 { Divider() }
                            let access = openAvailability(source.id)
                            StorageSourceTableRow(
                                columns: columns,
                                usesWideLayout: usesWideLayout,
                                source: source,
                                openAvailability: access,
                                unavailableMessage: unavailableMessage(source.id, access),
                                canReanalyze: canReanalyze(source.id),
                                openSource: openSource,
                                reanalyze: reanalyze
                            )
                        }
                    }
                }
            }
            .glassSurface(padding: 0)
        }
    }
}

private struct StorageSourceTableHeader: View {
    let columns: StorageSourceTableColumns
    let usesWideLayout: Bool

    var body: some View {
        Group {
            if usesWideLayout {
                wideContent
            } else {
                compactContent
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Color.primary.opacity(0.025))
        .accessibilityHidden(true)
    }

    private var wideContent: some View {
        HStack(spacing: 10) {
            HStack(spacing: 16) {
                header(L10n.text("来源"), width: columns.identity)
                header(L10n.text("来源分类"), width: columns.family)
                header(L10n.text("已分析空间"), width: columns.size, alignment: .trailing)
                header(L10n.text("磁盘卷"), width: columns.volumes)
                header(L10n.text("可安全清理"), width: columns.cleanup, alignment: .trailing)
                header(L10n.text("状态"), width: columns.status, alignment: .trailing)
            }
            Color.clear.frame(width: 34)
        }
    }

    private var compactContent: some View {
        HStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(L10n.text("来源"))
                    .lineLimit(1)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                header(L10n.text("已分析空间"), width: max(112, columns.size), alignment: .trailing)
                header(L10n.text("状态"), width: max(96, columns.status), alignment: .trailing)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 34)
        }
    }

    private func header(
        _ title: String,
        width: CGFloat,
        alignment: Alignment = .leading
    ) -> some View {
        Text(title)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
    }
}

private struct StorageSourceTableRow: View {
    let columns: StorageSourceTableColumns
    let usesWideLayout: Bool
    let source: StorageMapDashboardSource
    let openAvailability: StorageSourceResultAccess
    let unavailableMessage: String
    let canReanalyze: Bool
    let openSource: (StorageSourceID) -> String?
    let reanalyze: (StorageSourceID) -> Void

    @State private var isHovering = false
    @State private var isOpening = false
    @State private var accessFeedback: String?
    @State private var openTask: Task<Void, Never>?
    @State private var feedbackTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 10) {
            Button(action: requestOpen) {
                Group {
                    if usesWideLayout {
                        wideContent
                    } else {
                        compactContent
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(openAvailability.canPresent
                ? L10n.text("查看专属分析")
                : unavailableMessage)

            reanalysisControl
                .frame(width: 34, height: 30)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, usesWideLayout ? 0 : 6)
        .frame(minHeight: 56)
        .background(isHovering ? Color.primary.opacity(0.045) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onChange(of: openAvailability) { _, access in
            if access.canPresent {
                feedbackTask?.cancel()
                accessFeedback = nil
            }
        }
        .onDisappear {
            openTask?.cancel()
            feedbackTask?.cancel()
        }
    }

    private var wideContent: some View {
        HStack(spacing: 16) {
            identity.frame(width: columns.identity, alignment: .leading)
            family.frame(width: columns.family, alignment: .leading)
            size.frame(width: columns.size, alignment: .trailing)
            volumeDistribution.frame(width: columns.volumes, alignment: .leading)
            safeCleanup.frame(width: columns.cleanup, alignment: .trailing)
            status.frame(width: columns.status, alignment: .trailing)
        }
    }

    private var compactContent: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                identity
                HStack(spacing: 8) {
                    family
                    volumeDistribution
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            size.frame(width: max(112, columns.size), alignment: .trailing)
            status.frame(width: max(96, columns.status), alignment: .trailing)
        }
    }

    private var identity: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(source.family.color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            StorageSourceBrandIcon(
                sourceID: source.id,
                fallbackSymbol: source.item.symbol
            )
            Text(source.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if isOpening {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private var family: some View {
        Text(source.family.title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var size: some View {
        StorageMapNumberText(
            AgentStorageSizeFormatter.string(source.bytes),
            size: 13,
            weight: .medium,
            rounded: true
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var volumeDistribution: some View {
        if let accessFeedback {
            Label(accessFeedback, systemImage: "exclamationmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .truncationMode(.tail)
        } else if source.volumeAllocations.count == 1,
                  let allocation = source.volumeAllocations.first {
            Text(L10n.format(
                "%@ · %@",
                allocation.volumeName,
                AgentStorageSizeFormatter.string(allocation.allocatedBytes)
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        } else if source.volumeAllocations.count > 1 {
            Text(L10n.format("%d 块磁盘", source.volumeAllocations.count))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text("—")
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var safeCleanup: some View {
        if source.safeCleanupBytes > 0 {
            Text(AgentStorageSizeFormatter.string(source.safeCleanupBytes))
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(InstrumentDesign.ColorRole.cleanup)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    private var status: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(statusTitle)
                .font(.caption)
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .modifier(StorageMapTextShimmer(isActive: source.item.activity.state == .active))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var reanalysisControl: some View {
        switch StorageSourceReanalysisControlState.resolve(
            activityState: source.item.activity.state,
            canReanalyze: canReanalyze
        ) {
        case .available:
            Button {
                reanalyze(source.id)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(AppIconButtonStyle(size: 28))
            .help(L10n.text("重新分析"))
            .accessibilityLabel(L10n.text("重新分析"))
        case .analyzing:
            ProgressView()
                .controlSize(.mini)
                .allowsHitTesting(false)
        case .hidden:
            Color.clear.allowsHitTesting(false)
        }
    }

    private var statusTitle: String {
        switch source.item.activity.state {
        case .ready, .queued: L10n.text("等待分析")
        case .active: L10n.text("正在更新")
        case .complete: L10n.text("结果完整")
        case .partial: L10n.text("部分结果")
        }
    }

    private var statusColor: Color {
        switch source.item.activity.state {
        case .ready, .queued: .secondary
        case .active: .primary.opacity(0.72)
        case .complete: InstrumentDesign.ColorRole.healthy
        case .partial: .orange
        }
    }

    private func requestOpen() {
        guard !isOpening else { return }
        isOpening = true
        accessFeedback = nil
        openTask?.cancel()
        openTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            let feedback = openSource(source.id)
            isOpening = false
            if let feedback { presentFeedback(feedback) }
        }
    }

    private func presentFeedback(_ message: String) {
        accessFeedback = message
        feedbackTask?.cancel()
        feedbackTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            accessFeedback = nil
        }
    }
}

private func storageDashboardSourceColor(_ id: StorageSourceID) -> Color {
    switch id {
    case .chrome: .cyan
    case .go, .npm, .gradle, .androidSDK, .flutter, .homebrew: .green
    case .pnpm, .pip, .toolCaches: .teal
    case .bun: .yellow
    case .cocoaPods, .claude: .red
    case .rust: Color(red: 0.68, green: 0.34, blue: 0.24)
    case .xcode, .cursor: .indigo
    case .vscode: .blue
    case .simulators: .purple
    case .docker: .orange
    case .podman: Color(red: 0.62, green: 0.43, blue: 0.24)
    case .workspace: .gray
    case .codex, .openCode: .pink
    default: .secondary
    }
}
