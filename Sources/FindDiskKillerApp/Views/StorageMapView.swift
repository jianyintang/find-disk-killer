import AppKit
import FindDiskKillerCore
import SwiftUI

private enum StorageMapScope: String, CaseIterable, Identifiable {
    case all
    case applications
    case developerTools
    case containers
    case aiTools
    case workspaces

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L10n.text("全部")
        case .applications: L10n.text("应用与浏览器")
        case .developerTools: L10n.text("开发工具")
        case .containers: L10n.text("容器")
        case .aiTools: L10n.text("AI 工具")
        case .workspaces: L10n.text("工作区")
        }
    }

    func includes(_ family: StorageSourceFamily) -> Bool {
        switch self {
        case .all: true
        case .applications: family == .applications
        case .developerTools: family == .developerTools
        case .containers: family == .containers
        case .aiTools: family == .aiTools
        case .workspaces: family == .workspaces
        }
    }
}

private enum StorageMapRoute: Equatable {
    case overview
    case source(StorageSourceID)
    case agentAnalysis(AgentStorageProvider)
}

private struct StorageMapSourcePresentation: Identifiable {
    let candidate: StorageSourceCandidate
    let result: StorageSourceResult?
    let activity: StorageSourceActivityPresentation
    let displayBytes: UInt64

    var id: StorageSourceID { candidate.id }
}

struct StorageMapView: View {
    let model: StorageMapModel
    let agentStorage: AgentStorageModel
    let nodeRuntime: ClaudeNodeRuntimeStatusModel

    @State private var route: StorageMapRoute = .overview
    @State private var scope: StorageMapScope = .all
    @State private var displayedSourceOrder: [StorageSourceID] = []

    var body: some View {
        Group {
            switch route {
            case .overview:
                overview
            case .source(let sourceID):
                sourceDetail(sourceID)
            case .agentAnalysis(let provider):
                agentAnalysis(provider: provider)
            }
        }
        .task {
            await model.prepare()
            synchronizeDisplayedOrder(animated: false)
            if shouldStartInitialAnalysis {
                startFullAnalysis()
            }
        }
        .onChange(of: model.candidates.map(\.id)) { _, _ in
            synchronizeDisplayedOrder(animated: false)
            if shouldStartInitialAnalysis {
                startFullAnalysis()
            }
        }
        .onChange(of: isAnyAnalysisRunning, initial: true) { wasRunning, isRunning in
            if isRunning {
                stabilizeDisplayedOrder()
            } else {
                synchronizeDisplayedOrder(animated: wasRunning)
            }
        }
        .focusedValue(\.agentStorageRefreshAction, isFullAnalysisRunning ? nil : {
            startFullAnalysis()
        })
        .focusedValue(\.agentStorageBackAction, route == .overview ? nil : {
            route = .overview
        })
    }

    private var overview: some View {
        GeometryReader { proxy in
            Group {
                if model.phase == .detecting {
                    detectorLoading
                } else if model.candidates.isEmpty {
                    noSources
                } else if !hasUnifiedResults, !isFullAnalysisRunning {
                    StorageMapFirstRunView(
                        candidates: model.candidates,
                        errorMessage: model.errorMessage,
                        startAnalysis: startFullAnalysis
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            StorageMapSummaryBand(
                                model: model,
                                isAgentScanning: agentStorage.isScanning,
                                startAnalysis: startFullAnalysis,
                                stopAnalysis: stopFullAnalysis
                            )
                            Divider()
                            Section {
                                sourceWorkspace(width: proxy.size.width)
                            } header: {
                                VStack(spacing: 0) {
                                    scopeBar
                                    Divider()
                                }
                                .background(.bar)
                            }
                        }
                    }
                    .scrollIndicators(.visible)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    @ViewBuilder
    private func sourceWorkspace(width: CGFloat) -> some View {
        if width >= 560 {
            sourceWorkbench(width: width)
        } else {
            minimumWidthNotice
                .frame(minHeight: 420)
        }
    }

    private var scopeBar: some View {
        HStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                Picker(L10n.text("来源分类"), selection: $scope) {
                    ForEach(StorageMapScope.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Picker(L10n.text("来源分类"), selection: $scope) {
                    ForEach(StorageMapScope.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .frame(maxWidth: 220)
            }
            Spacer(minLength: 8)
            if model.snapshot != nil {
                Text(L10n.format("%d 个来源", visibleItems.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private func sourceWorkbench(width: CGFloat) -> some View {
        let items = visibleItems
        return LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().padding(.leading, 72) }
                StorageSourceWorkbenchRow(
                    item: item,
                    activity: item.activity,
                    displayBytes: item.displayBytes,
                    usesCompactLayout: width < 820,
                    canReanalyze: canReanalyze(item.id),
                    open: { openSource(item.id) },
                    reanalyze: { reanalyze(item.id) }
                )
            }
        }
        .animation(
            .snappy(duration: 0.42, extraBounce: 0),
            value: items.map(\.id)
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.18))
        .clipped()
    }

    private var detectorLoading: some View {
        StorageMapDiscoveryView(candidates: model.candidates)
    }

    private var noSources: some View {
        ContentUnavailableView {
            Label(L10n.text("未发现支持的来源"), systemImage: "externaldrive.badge.questionmark")
        } description: {
            Text(L10n.text("安装受支持的工具后重新探测。"))
        } actions: {
            Button(L10n.text("重新探测")) { model.retryDetection() }
                .buttonStyle(AppActionButtonStyle(kind: .primary))
        }
    }

    private var minimumWidthNotice: some View {
        ContentUnavailableView(
            L10n.text("增大窗口以查看空间地图"),
            systemImage: "rectangle.expand.vertical",
            description: Text(L10n.text("当前选择已保留。折叠侧栏可获得更多内容空间。"))
        )
    }

    @ViewBuilder
    private func sourceDetail(_ sourceID: StorageSourceID) -> some View {
        if let item = item(for: sourceID) {
            StorageSourceDetailView(
                item: item,
                isScanning: isScanning(sourceID),
                isFullAnalysisRunning: isFullAnalysisRunning,
                hasFullDiskRepositoryAccess: model.hasFullDiskRepositoryAccess,
                startAnalysis: { model.startAnalysis(sourceID: sourceID) },
                refreshRepositoryAuthorization: model.refreshRepositoryAuthorization,
                goBack: { route = .overview },
                didCleanup: { model.startAnalysis(sourceID: sourceID) }
            )
        } else {
            ContentUnavailableView(L10n.text("来源不可用"), systemImage: "questionmark.folder")
                .toolbar {
                    Button(L10n.text("返回"), systemImage: "chevron.left") { route = .overview }
                }
        }
    }

    private func agentAnalysis(provider: AgentStorageProvider) -> some View {
        AgentStorageView(
            model: agentStorage,
            initialProvider: provider,
            allowsAnalysisActions: false,
            nodeRuntime: nodeRuntime,
            providerExitAction: { route = .overview }
        )
    }

    private func openSource(_ sourceID: StorageSourceID) {
        guard canPresentResult(sourceID) else { return }
        switch StorageSourceDestination.destination(for: sourceID) {
        case .tailoredAnalysis:
            route = .source(sourceID)
        case .agentAnalysis(let provider):
            route = .agentAnalysis(provider)
        }
    }

    private func canPresentResult(_ sourceID: StorageSourceID) -> Bool {
        if sourceID == .workspace,
           model.candidates.contains(where: { $0.id == .workspace }) {
            return true
        }
        return StorageSourceResultAccess.canPresent(
            sourceID: sourceID,
            storageSnapshot: model.snapshot,
            agentSnapshot: agentStorage.snapshot,
            requiredAgentProviders: requiredAgentProviders
        )
    }

    private var requiredAgentProviders: Set<AgentStorageProvider> {
        Set(model.candidates.compactMap { $0.id.agentStorageProvider })
    }

    private var hasUnifiedResults: Bool {
        guard let snapshot = model.snapshot,
              model.candidates.allSatisfy({ candidate in
                  candidate.id == .workspace && candidate.roots.isEmpty
                      || snapshot.result(for: candidate.id) != nil
              }) else {
            return false
        }
        let completedProviders = Set(agentStorage.snapshot?.providers.map(\.provider) ?? [])
        return requiredAgentProviders.isSubset(of: completedProviders)
    }

    private var shouldStartInitialAnalysis: Bool {
        model.phase == .ready
            && !model.candidates.isEmpty
            && !hasUnifiedResults
            && !isFullAnalysisRunning
            && model.errorMessage == nil
    }

    private func agentSummary(
        for sourceID: StorageSourceID
    ) -> AgentStorageProviderSummary? {
        guard let provider = sourceID.agentStorageProvider else { return nil }
        return agentStorage.snapshot?.providers.first { $0.provider == provider }
    }

    private func activityPresentation(
        candidate: StorageSourceCandidate,
        result: StorageSourceResult?
    ) -> StorageSourceActivityPresentation {
        let isRunning = model.phase == .scanning || model.phase == .stopping
        if let provider = candidate.id.agentStorageProvider {
            return .agent(
                provider: provider,
                candidate: candidate,
                summary: agentSummary(for: candidate.id),
                progress: agentStorage.progressByProvider[provider],
                isScanning: agentStorage.isAnalyzing(provider)
            )
        } else {
            if candidate.id == .workspace,
               candidate.roots.isEmpty,
               !model.isAnalyzingSource(.workspace) {
                return .workspace(candidate: candidate, result: result)
            }
            return .regular(
                candidate: candidate,
                result: result,
                progress: model.progressBySource[candidate.id],
                isFullScanRunning: isRunning || model.isAnalyzingSource(candidate.id)
            )
        }
    }

    private func reanalyze(_ sourceID: StorageSourceID) {
        guard canReanalyze(sourceID) else { return }
        stabilizeDisplayedOrder()
        model.startAnalysis(sourceID: sourceID)
        if let provider = sourceID.agentStorageProvider {
            agentStorage.startAnalysis(provider: provider)
        }
    }

    private func canReanalyze(_ sourceID: StorageSourceID) -> Bool {
        guard !isFullAnalysisRunning,
              !isReanalyzing(sourceID),
              model.snapshot?.result(for: sourceID) != nil else { return false }
        if sourceID.agentStorageProvider != nil {
            return agentSummary(for: sourceID) != nil
        }
        return true
    }

    private func isReanalyzing(_ sourceID: StorageSourceID) -> Bool {
        let storageIsRunning = model.reanalyzingSourceIDs.contains(sourceID)
        guard let provider = sourceID.agentStorageProvider else { return storageIsRunning }
        return storageIsRunning || agentStorage.reanalyzingProviders.contains(provider)
    }

    private var isFullAnalysisRunning: Bool {
        model.isFullAnalysisRunning(including: agentStorage)
    }

    private var isAnyAnalysisRunning: Bool {
        isFullAnalysisRunning
            || !model.reanalyzingSourceIDs.isEmpty
            || !agentStorage.reanalyzingProviders.isEmpty
    }

    private func startFullAnalysis() {
        stabilizeDisplayedOrder()
        model.startAnalysis(including: agentStorage)
    }

    private func stopFullAnalysis() {
        model.stopAnalysis(including: agentStorage)
    }

    private var visibleItems: [StorageMapSourcePresentation] {
        let items = model.candidates
            .filter { scope.includes($0.descriptor.family) }
            .map(makePresentation)
        let positions = Dictionary(
            uniqueKeysWithValues: displayedSourceOrder.enumerated().map { ($1, $0) }
        )
        return items.sorted { lhs, rhs in
            let lhsPosition = positions[lhs.id] ?? Int.max
            let rhsPosition = positions[rhs.id] ?? Int.max
            if lhsPosition != rhsPosition { return lhsPosition < rhsPosition }
            return lhs.id.rawValue < rhs.id.rawValue
        }
    }

    private func stabilizeDisplayedOrder() {
        displayedSourceOrder = StorageSourceDisplayOrdering.stabilized(
            current: displayedSourceOrder,
            available: model.candidates.map(\.id)
        )
    }

    private func synchronizeDisplayedOrder(animated: Bool) {
        guard !isAnyAnalysisRunning else {
            stabilizeDisplayedOrder()
            return
        }
        let presentations = model.candidates.map(makePresentation)
        let finalOrder = presentations.sorted { lhs, rhs in
            StorageSourceUsageOrdering.precedes(
                lhsID: lhs.id,
                lhsTitle: lhs.candidate.descriptor.title,
                lhsBytes: lhs.displayBytes,
                rhsID: rhs.id,
                rhsTitle: rhs.candidate.descriptor.title,
                rhsBytes: rhs.displayBytes
            )
        }.map(\.id)
        let update = { displayedSourceOrder = finalOrder }
        if animated {
            withAnimation(.snappy(duration: 0.42, extraBounce: 0), update)
        } else {
            update()
        }
    }

    private func makePresentation(
        _ candidate: StorageSourceCandidate
    ) -> StorageMapSourcePresentation {
        let result = model.snapshot?.result(for: candidate.id)
        let activity = activityPresentation(candidate: candidate, result: result)
        return StorageMapSourcePresentation(
            candidate: candidate,
            result: result,
            activity: activity,
            displayBytes: activity.processedBytes
                ?? model.presentationAllocatedBytes(for: candidate.id)
                ?? result?.allocatedBytes
                ?? 0
        )
    }

    private func item(for sourceID: StorageSourceID) -> StorageMapSourcePresentation? {
        guard let candidate = model.candidates.first(where: { $0.id == sourceID }) else {
            return nil
        }
        return makePresentation(candidate)
    }

    private func isScanning(_ sourceID: StorageSourceID) -> Bool {
        guard let provider = sourceID.agentStorageProvider else {
            return model.isAnalyzingSource(sourceID)
        }
        return model.isAnalyzingSource(sourceID) || agentStorage.isAnalyzing(provider)
    }

    @ViewBuilder
    private func measuredValue(_ bytes: UInt64?) -> some View {
        if let bytes {
            Text(AgentStorageSizeFormatter.string(bytes))
                .font(.system(.body, design: .monospaced))
                .monospacedDigit()
        } else if model.phase == .scanning {
            Text("000.0 MiB")
                .font(.system(.body, design: .monospaced))
                .redacted(reason: .placeholder)
                .accessibilityHidden(true)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func reclaimableEvidence(_ result: StorageSourceResult?) -> some View {
        if let result, result.reclaimableCandidateBytes > 0 {
            Text(L10n.format("文件实测 %@", AgentStorageSizeFormatter.string(result.reclaimableCandidateBytes)))
                .font(.callout)
        } else if result != nil {
            Text(L10n.text("仅分析"))
                .foregroundStyle(.secondary)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

private struct StorageMapDiscoveryView: View {
    let candidates: [StorageSourceCandidate]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    confirmedSources
                    discoveryScope
                }
                .frame(maxWidth: 1120)
                .frame(maxWidth: .infinity, minHeight: max(560, proxy.size.height - 64), alignment: .top)
                .padding(.horizontal, 32)
                .padding(.top, 72)
                .padding(.bottom, 56)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                boundaryBar
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .accessibilityElement(children: .contain)
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.46, extraBounce: 0),
            value: candidates.map(\.id)
        )
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 28) {
                headerCopy
                Spacer(minLength: 24)
                latestConfirmation
            }
            VStack(alignment: .leading, spacing: 18) {
                headerCopy
                latestConfirmation
            }
        }
    }

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.text("正在发现本机存储来源"), systemImage: "externaldrive.badge.magnifyingglass")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text(L10n.format("%d 个应用与工具已确认", candidates.count))
                .font(.title.weight(.semibold))
                .contentTransition(.numericText(value: Double(candidates.count)))
            Text(L10n.text("确认后立即加入下方列表，完成后自动开始分析。"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var latestConfirmation: some View {
        if let candidate = candidates.last {
            HStack(spacing: 12) {
                StorageSourceBrandIcon(
                    sourceID: candidate.id,
                    fallbackSymbol: candidate.descriptor.symbol
                )
                VStack(alignment: .leading, spacing: 3) {
                    Label(L10n.text("刚刚确认"), systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                    Text(candidate.descriptor.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(discoveryDetail(for: candidate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .id(candidate.id)
            .transition(.blurReplace.combined(with: .opacity))
            .frame(minWidth: 230, alignment: .leading)
        } else {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("正在检查已知应用、工具与数据位置"))
                        .font(.callout.weight(.medium))
                    Text(L10n.text("发现仍在进行"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 230, alignment: .leading)
        }
    }

    private var confirmedSources: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("已确认的应用与工具"))
                    .font(.headline)
                Spacer()
                if !candidates.isEmpty {
                    Text(L10n.format("%d 个已确认", candidates.count))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if candidates.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在检查已知应用、工具与数据位置"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 64)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 10)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(candidates) { candidate in
                        HStack(spacing: 10) {
                            StorageSourceBrandIcon(
                                sourceID: candidate.id,
                                fallbackSymbol: candidate.descriptor.symbol
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.descriptor.title)
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                                Text(discoveryDetail(for: candidate))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.green)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 58)
                        .background(
                            Color(nsColor: .controlBackgroundColor).opacity(0.52),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .transition(.blurReplace.combined(with: .opacity))
                    }
                }
            }
        }
    }

    private var discoveryScope: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("正在并行确认"))
                    .font(.headline)
                Spacer()
                Label(L10n.text("只读取位置，不读取文件内容"), systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(Self.areas) { area in
                    discoveryArea(area)
                }
            }
        }
    }

    private func discoveryDetail(for candidate: StorageSourceCandidate) -> String {
        if candidate.id == .workspace, candidate.roots.isEmpty {
            return L10n.text("在详情中分析")
        }
        return L10n.format("%d 个已知位置", candidate.roots.count)
    }

    private func discoveryArea(_ area: StorageMapDiscoveryArea) -> some View {
        let count = candidates.filter { area.includes($0.descriptor.family) }.count
        return HStack(spacing: 12) {
            Image(systemName: area.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(area.color)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text(area.title))
                    .font(.callout.weight(.semibold))
                Text(count > 0 ? L10n.format("%d 个已确认", count) : L10n.text("正在检查"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if count > 0 {
                Text("\(count)")
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(count)))
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(count > 0 ? area.color.opacity(0.7) : Color.primary.opacity(0.1))
                .frame(height: 2)
        }
        .accessibilityElement(children: .combine)
    }

    private var boundaryBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 22) {
                boundary(L10n.text("本机完成"), symbol: "macbook")
                boundary(L10n.text("只读元数据"), symbol: "doc.text.magnifyingglass")
                boundary(L10n.text("不执行清理"), symbol: "hand.raised.fill")
                Spacer(minLength: 12)
                Text(L10n.format("%d 个应用与工具已确认", candidates.count))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }
            HStack(spacing: 12) {
                Label(L10n.text("本机只读分析，不执行清理"), systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 28)
        .frame(minHeight: 64)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func boundary(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private static let areas: [StorageMapDiscoveryArea] = [
        .init(
            id: "applications",
            title: "应用数据",
            symbol: "app.badge.checkmark",
            color: .blue,
            includes: { $0 == .applications }
        ),
        .init(
            id: "developer-tools",
            title: "开发工具",
            symbol: "hammer.fill",
            color: .green,
            includes: { $0 == .developerTools }
        ),
        .init(
            id: "containers",
            title: "容器环境",
            symbol: "shippingbox.fill",
            color: .orange,
            includes: { $0 == .containers }
        ),
        .init(
            id: "ai-tools",
            title: "AI 工具",
            symbol: "sparkles",
            color: .purple,
            includes: { $0 == .aiTools }
        ),
    ]
}

private struct StorageMapDiscoveryArea: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let color: Color
    let includes: (StorageSourceFamily) -> Bool
}

private struct StorageSourceWorkbenchRow: View {
    let item: StorageMapSourcePresentation
    let activity: StorageSourceActivityPresentation
    let displayBytes: UInt64
    let usesCompactLayout: Bool
    let canReanalyze: Bool
    let open: () -> Void
    let reanalyze: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                Group {
                    if usesCompactLayout {
                        compactContent
                    } else {
                        wideContent
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
            .accessibilityHint(L10n.text("查看专属分析"))

            reanalysisControl

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 12)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: usesCompactLayout ? 108 : 92)
        .frame(maxWidth: .infinity)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 7))
        .clipped()
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
    }

    private var wideContent: some View {
        HStack(spacing: 18) {
            identity
                .frame(minWidth: 185, idealWidth: 220, maxWidth: 260, alignment: .leading)
            activityContent
                .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
            metrics
                .frame(width: 180, alignment: .trailing)
            stateBadge
                .frame(width: 106, alignment: .trailing)
        }
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                identity
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                Spacer(minLength: 10)
                metrics
                    .fixedSize(horizontal: true, vertical: false)
            }
            HStack(alignment: .top, spacing: 12) {
                activityContent
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 48)
                stateBadge
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private var identity: some View {
        HStack(spacing: 12) {
            StorageSourceBrandIcon(sourceID: item.id, fallbackSymbol: item.candidate.descriptor.symbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.candidate.descriptor.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(item.candidate.descriptor.family.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var activityContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                if activity.state == .active {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle()
                        .fill(stateColor.opacity(0.85))
                        .frame(width: 6, height: 6)
                }
                Text(activity.phaseTitle)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(activity.state == .active ? Color.primary : stateColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text(activity.workDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let supportingDetail = activity.supportingDetail {
                Text(supportingDetail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var metrics: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(AgentStorageSizeFormatter.string(displayBytes))
                .font(.system(.callout, design: .monospaced, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.28), value: displayBytes)
            if let count = activity.processedEntryCount {
                Text(L10n.format("%d 项", count))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.text("尚无实测数据"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var stateBadge: some View {
        Label(stateTitle, systemImage: stateSymbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(stateColor)
            .lineLimit(1)
    }

    @ViewBuilder
    private var reanalysisControl: some View {
        switch StorageSourceReanalysisControlState.resolve(
            activityState: activity.state,
            canReanalyze: canReanalyze
        ) {
        case .available:
            Button(action: reanalyze) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(AppIconButtonStyle(size: 30))
            .help(L10n.text("重新分析"))
            .accessibilityLabel(L10n.text("重新分析"))
        case .analyzing:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 28, height: 28)
                .background(
                    Color.accentColor.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .help(L10n.text("正在分析"))
                .accessibilityLabel(L10n.text("正在分析"))
        case .hidden:
            Color.clear
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        }
    }

    private var rowBackground: Color {
        if isHovering { return Color.primary.opacity(0.055) }
        return .clear
    }

    private var stateTitle: String {
        switch activity.state {
        case .ready: L10n.text("可分析")
        case .queued: L10n.text("等待")
        case .active: L10n.text("分析中")
        case .complete: L10n.text("已完成")
        case .partial: L10n.text("部分结果")
        }
    }

    private var stateSymbol: String {
        switch activity.state {
        case .ready: "arrow.right.circle.fill"
        case .queued: "clock"
        case .active: "waveform.path.ecg"
        case .complete: "checkmark.circle.fill"
        case .partial: "exclamationmark.triangle.fill"
        }
    }

    private var stateColor: Color {
        switch activity.state {
        case .ready: .accentColor
        case .queued: .secondary
        case .active: .accentColor
        case .complete: .green
        case .partial: .orange
        }
    }
}

@MainActor
private struct StorageSourceBrandIcon: View {
    let sourceID: StorageSourceID
    let fallbackSymbol: String

    var body: some View {
        Group {
            if let image = Self.images[sourceID] {
                if sourceID == .codex {
                    Image(nsImage: image)
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .foregroundStyle(.primary)
                        .padding(5)
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(3)
                }
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .frame(width: 40, height: 40)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }

    private static let images: [StorageSourceID: NSImage] = {
        var values: [StorageSourceID: NSImage] = [:]
        values[.chrome] = applicationIcon(
            bundleIdentifiers: ["com.google.Chrome"],
            paths: ["/Applications/Google Chrome.app"]
        ) ?? resourceImage("chrome")
        values[.xcode] = applicationIcon(
            bundleIdentifiers: ["com.apple.dt.Xcode"],
            paths: ["/Applications/Xcode.app"]
        ) ?? resourceImage("xcode")
        values[.simulators] = applicationIcon(
            bundleIdentifiers: ["com.apple.iphonesimulator"],
            paths: ["/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app"]
        )
        values[.docker] = applicationIcon(
            bundleIdentifiers: ["com.docker.docker"],
            paths: ["/Applications/Docker.app"]
        ) ?? resourceImage("docker")
        values[.go] = resourceImage("go")
        values[.npm] = resourceImage("npm")
        values[.pnpm] = resourceImage("pnpm")
        values[.bun] = resourceImage("bun")
        values[.pip] = resourceImage("python")
        values[.podman] = applicationIcon(
            bundleIdentifiers: ["com.redhat.PodmanDesktop"],
            paths: ["/Applications/Podman Desktop.app"]
        ) ?? resourceImage("podman")
        values[.codex] = resourceImage("codex-openai")
        values[.claude] = resourceImage("claude-code")
        values[.openCode] = applicationIcon(
            bundleIdentifiers: ["ai.opencode.desktop"],
            paths: ["/Applications/OpenCode.app"]
        )
        return values
    }()

    private static func applicationIcon(
        bundleIdentifiers: [String],
        paths: [String]
    ) -> NSImage? {
        for identifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        for path in paths where FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return nil
    }

    private static func resourceImage(_ name: String) -> NSImage? {
        guard let url = AppResourceBundle.value.url(forResource: name, withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

private struct StorageMapSummaryBand: View {
    let model: StorageMapModel
    let isAgentScanning: Bool
    let startAnalysis: () -> Void
    let stopAnalysis: () -> Void

    var body: some View {
        let volumes = model.presentationVolumes
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                wideSummary
                compactSummary
            }

            if !volumes.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.text("磁盘空间构成"))
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 12)
                    Text(L10n.format("%d 块磁盘", volumes.count))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                StorageVolumePortfolio(
                    volumes: volumes,
                    sourceTitles: Dictionary(
                        uniqueKeysWithValues: model.candidates.map {
                            ($0.id, $0.descriptor.title)
                        }
                    )
                )
            } else if model.phase == .scanning || model.phase == .stopping {
                Label(
                    L10n.text("完成空间归属后显示各磁盘的应用、其它与可用空间"),
                    systemImage: "externaldrive.badge.timemachine"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            } else {
                Label(L10n.text("刷新分析以生成磁盘级空间构成"), systemImage: "externaldrive.badge.questionmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
    }

    private var wideSummary: some View {
        HStack(spacing: 20) {
            primarySummary
                .frame(minWidth: 220, alignment: .leading)
            summaryDivider
            summaryMetric(L10n.text("来源"), sourceCount)
            summaryMetric(L10n.text("文件条目"), entryCount)
            summaryMetric(L10n.text("可重建"), reclaimableValue)
            summaryMetric(L10n.text("磁盘卷"), volumeCount)
            Spacer(minLength: 8)
            analysisButton
        }
    }

    private var compactSummary: some View {
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                primarySummary
                Spacer(minLength: 12)
                analysisButton
            }
            HStack(spacing: 20) {
                summaryMetric(L10n.text("来源"), sourceCount)
                summaryMetric(L10n.text("文件条目"), entryCount)
                summaryMetric(L10n.text("可重建"), reclaimableValue)
                summaryMetric(L10n.text("磁盘卷"), volumeCount)
            }
        }
    }

    private var primarySummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(primaryTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(summaryValue)
                .font(.system(size: 28, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(summaryDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var summaryDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.7))
            .frame(width: 1, height: 46)
    }

    private func summaryMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(minWidth: 86, alignment: .leading)
    }

    private var analysisButton: some View {
        Button(action: isAnalysisRunning ? stopAnalysis : startAnalysis) {
            Image(systemName: isAnalysisRunning ? "stop.fill" : "arrow.clockwise")
        }
        .buttonStyle(AppIconButtonStyle(size: 34))
        .help(isAnalysisRunning ? L10n.text("停止分析") : L10n.text("刷新空间地图"))
        .disabled(model.phase == .detecting || model.phase == .stopping || model.candidates.isEmpty)
    }

    private var isAnalysisRunning: Bool {
        model.phase == .scanning || model.phase == .stopping || isAgentScanning
    }

    private var summaryValue: String {
        if let bytes = model.presentationTotalAllocatedBytes {
            return AgentStorageSizeFormatter.string(bytes)
        }
        if model.phase == .detecting { return "—" }
        return L10n.format("%d 个", model.candidates.count)
    }

    private var summaryDetail: String {
        if model.phase == .scanning || model.phase == .stopping,
           let progress = model.progress {
            var details: [String] = []
            if progress.totalSourceCount > 0 {
                details.append(L10n.format(
                    "进度 %d / %d",
                    min(progress.completedSourceCount, progress.totalSourceCount),
                    progress.totalSourceCount
                ))
            }
            if progress.processedEntryCount > 0 {
                details.append(L10n.format("已检查 %d 项", progress.processedEntryCount))
            }
            if !details.isEmpty { return details.joined(separator: " · ") }
            return L10n.text("正在查找已安装工具")
        }
        guard let snapshot = model.snapshot else {
            return L10n.text("等待你开始只读分析")
        }
        return L10n.format(
            "%d 个来源 · 更新于 %@",
            snapshot.results.count,
            L10n.date(snapshot.scannedAt, date: .omitted, time: .shortened)
        )
    }

    private var sourceCount: String {
        if model.phase == .scanning || model.phase == .stopping,
           let progress = model.progress,
           progress.totalSourceCount > 0 {
            return "\(min(progress.completedSourceCount, progress.totalSourceCount)) / \(progress.totalSourceCount)"
        }
        return (model.snapshot?.results.count ?? model.candidates.count).formatted()
    }

    private var entryCount: String {
        model.presentationEntryCount?.formatted() ?? "—"
    }

    private var reclaimableValue: String {
        if model.phase == .scanning || model.phase == .stopping {
            return L10n.text("分析中")
        }
        guard let results = model.snapshot?.results else { return "—" }
        let bytes = results.reduce(UInt64(0)) {
            $0.addingClamped($1.reclaimableCandidateBytes)
        }
        return AgentStorageSizeFormatter.string(bytes)
    }

    private var volumeCount: String {
        let count = model.presentationVolumes.count
        return count > 0 ? count.formatted() : "—"
    }

    private var primaryTitle: String {
        if model.phase == .scanning || model.phase == .stopping {
            return L10n.text("正在分析")
        }
        return model.snapshot == nil ? L10n.text("已发现来源") : L10n.text("已分析空间")
    }
}

private struct StorageVolumePortfolio: View {
    let volumes: [StorageVolumeSnapshot]
    let sourceTitles: [StorageSourceID: String]

    var body: some View {
        StorageVolumeAdaptiveLayout(minimumItemWidth: 420, spacing: 12) {
            ForEach(volumes) { volume in
                StorageVolumeComposition(
                    volume: volume,
                    sourceTitles: sourceTitles
                )
            }
        }
    }
}

private struct StorageVolumeAdaptiveLayout: Layout {
    let minimumItemWidth: CGFloat
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = max(minimumItemWidth, proposal.width ?? minimumItemWidth)
        let columns = columnCount(width: width, itemCount: subviews.count)
        let itemWidth = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        var rowHeights = Array(repeating: CGFloat(0), count: rowCount(itemCount: subviews.count, columns: columns))
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.init(width: itemWidth, height: nil))
            rowHeights[index / columns] = max(rowHeights[index / columns], size.height)
        }
        return CGSize(
            width: width,
            height: rowHeights.reduce(0, +) + CGFloat(max(0, rowHeights.count - 1)) * spacing
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }
        let columns = columnCount(width: bounds.width, itemCount: subviews.count)
        let itemWidth = (bounds.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let rows = rowCount(itemCount: subviews.count, columns: columns)
        var rowHeights = Array(repeating: CGFloat(0), count: rows)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.init(width: itemWidth, height: nil))
            rowHeights[index / columns] = max(rowHeights[index / columns], size.height)
        }
        var rowOrigins = Array(repeating: bounds.minY, count: rows)
        for row in 1..<rows {
            rowOrigins[row] = rowOrigins[row - 1] + rowHeights[row - 1] + spacing
        }
        for index in subviews.indices {
            let row = index / columns
            let column = index % columns
            subviews[index].place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(column) * (itemWidth + spacing),
                    y: rowOrigins[row]
                ),
                anchor: .topLeading,
                proposal: .init(width: itemWidth, height: rowHeights[row])
            )
        }
    }

    private func columnCount(width: CGFloat, itemCount: Int) -> Int {
        StorageVolumeLayoutPolicy.columnCount(
            width: width,
            itemCount: itemCount,
            minimumItemWidth: minimumItemWidth,
            spacing: spacing
        )
    }

    private func rowCount(itemCount: Int, columns: Int) -> Int {
        (itemCount + columns - 1) / columns
    }
}

private struct StorageCapacitySegment: Identifiable {
    let id: String
    let title: String
    let bytes: UInt64
    let share: CGFloat
    let offset: CGFloat
    let color: Color
}

private struct StorageVolumeComposition: View {
    let volume: StorageVolumeSnapshot
    let sourceTitles: [StorageSourceID: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: volume.mountPath == "/" ? "internaldrive.fill" : "externaldrive.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(volume.mountPath == "/" ? Color.secondary : Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(volume.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(volume.mountPath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(usedPercentage)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                    Text(L10n.text("已用"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            StorageCapacityRibbon(
                segments: segments,
                usedShare: capacityShare(volume.usedBytes)
            )

            HStack(spacing: 0) {
                spaceFact(L10n.text("已识别"), volume.analyzedBytes, color: .accentColor)
                factDivider
                spaceFact(L10n.text("其它"), volume.otherBytes, color: .secondary)
                factDivider
                spaceFact(L10n.text("可用空间"), volume.availableCapacity, color: .primary)
            }

            sourceSummary
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.62), lineWidth: 0.5)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .animation(.smooth(duration: 0.34), value: volume)
    }

    private var usedPercentage: String {
        guard volume.totalCapacity > 0 else { return "0%" }
        return (Double(volume.usedBytes) / Double(volume.totalCapacity)).formatted(
            .percent.precision(.fractionLength(0))
        )
    }

    private var factDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.65))
            .frame(width: 1, height: 34)
    }

    private func spaceFact(_ title: String, _ bytes: UInt64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(AgentStorageSizeFormatter.string(bytes))
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var sourceSummary: some View {
        let usages = Array(volume.sourceUsages.prefix(4))
        if usages.isEmpty {
            HStack(spacing: 7) {
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.tertiary)
                Text(L10n.text("未识别工具占用"))
                Text(L10n.text("已用空间归入其它"))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("已识别"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                ForEach(Array(stride(from: 0, to: usages.count, by: 2)), id: \.self) { index in
                    HStack(spacing: 18) {
                        sourceUsageCell(usages[index])
                        if index + 1 < usages.count {
                            sourceUsageCell(usages[index + 1])
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity, minHeight: 16)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
    }

    private func sourceUsageCell(_ usage: StorageVolumeSourceUsage) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(storageSourceColor(usage.sourceID))
                .frame(width: 7, height: 7)
            Text(sourceTitles[usage.sourceID] ?? usage.sourceID.rawValue)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(AgentStorageSizeFormatter.string(usage.allocatedBytes))
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func capacityShare(_ bytes: UInt64) -> CGFloat {
        guard volume.totalCapacity > 0 else { return 0 }
        return max(0, min(1, CGFloat(Double(bytes) / Double(volume.totalCapacity))))
    }

    private var segments: [StorageCapacitySegment] {
        let total = max(1, volume.totalCapacity)
        let analyzed = volume.analyzedBytes
        let used = volume.usedBytes
        let scale = analyzed > used && analyzed > 0 ? Double(used) / Double(analyzed) : 1
        var items = volume.sourceUsages.map { usage in
            (
                id: usage.sourceID.rawValue,
                title: sourceTitles[usage.sourceID] ?? usage.sourceID.rawValue,
                bytes: usage.allocatedBytes,
                displayBytes: Double(usage.allocatedBytes) * scale,
                color: storageSourceColor(usage.sourceID)
            )
        }
        if volume.otherBytes > 0 {
            items.append(("other", L10n.text("其它"), volume.otherBytes, Double(volume.otherBytes), Color.secondary.opacity(0.62)))
        }
        if volume.availableCapacity > 0 {
            items.append(("available", L10n.text("可用空间"), volume.availableCapacity, Double(volume.availableCapacity), Color(nsColor: .separatorColor).opacity(0.38)))
        }
        var offset = CGFloat(0)
        return items.map { item in
            let share = CGFloat(item.displayBytes / Double(total))
            defer { offset += share }
            return StorageCapacitySegment(
                id: item.id,
                title: item.title,
                bytes: item.bytes,
                share: max(0, min(1 - offset, share)),
                offset: offset,
                color: item.color
            )
        }
    }

    private func storageSourceColor(_ id: StorageSourceID) -> Color {
        switch id {
        case .chrome: .cyan
        case .go: .green
        case .npm: .mint
        case .pnpm: .teal
        case .bun: .yellow
        case .pip: .blue
        case .xcode: .indigo
        case .simulators: .purple
        case .docker: .orange
        case .podman: .brown
        case .workspace: .gray
        case .codex: .pink
        case .claude: .red
        default: .secondary
        }
    }
}

private struct StorageCapacityRibbon: View {
    let segments: [StorageCapacitySegment]
    let usedShare: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.055))
                Rectangle()
                    .fill(Color.primary.opacity(0.2))
                    .frame(width: proxy.size.width * usedShare)
                ForEach(identifiedSegments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(2.5, proxy.size.width * segment.share - 0.75))
                        .offset(x: proxy.size.width * segment.offset)
                        .help("\(segment.title)  \(AgentStorageSizeFormatter.string(segment.bytes))")
                        .accessibilityLabel(segment.title)
                        .accessibilityValue(AgentStorageSizeFormatter.string(segment.bytes))
                }
                Rectangle()
                    .fill(Color.primary.opacity(0.45))
                    .frame(width: 1)
                    .offset(x: max(0, proxy.size.width * usedShare - 0.5))
                    .accessibilityHidden(true)
                LinearGradient(
                    colors: [Color.white.opacity(0.18), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
        }
        .frame(height: 16)
        .accessibilityElement(children: .contain)
    }

    private var identifiedSegments: [StorageCapacitySegment] {
        segments.filter { $0.id != "other" && $0.id != "available" }
    }
}

private struct StorageSourceIdentity: View {
    let item: StorageMapSourcePresentation
    let isScanning: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.candidate.descriptor.symbol)
                .foregroundStyle(item.candidate.descriptor.family.color)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.candidate.descriptor.title)
                    .lineLimit(1)
                Text(item.candidate.descriptor.family.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if isScanning {
                ProgressView().controlSize(.mini)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StorageSourceStatus: View {
    let result: StorageSourceResult?
    let isScanning: Bool

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private var title: String {
        if isScanning { return L10n.text("正在更新") }
        guard let result else { return L10n.text("等待分析") }
        if result.isComplete { return L10n.text("结果完整") }
        return L10n.text("部分结果")
    }

    private var symbol: String {
        if isScanning { return "arrow.triangle.2.circlepath" }
        guard let result else { return "clock" }
        return result.isComplete ? "checkmark.circle" : "exclamationmark.triangle"
    }

    private var color: Color {
        if isScanning { return .accentColor }
        guard let result else { return .secondary }
        return result.isComplete ? .secondary : .orange
    }
}

private struct StorageSourceDetailView: View {
    let item: StorageMapSourcePresentation
    let isScanning: Bool
    let isFullAnalysisRunning: Bool
    let hasFullDiskRepositoryAccess: Bool
    let startAnalysis: () -> Void
    let refreshRepositoryAuthorization: () -> Bool
    let goBack: () -> Void
    let didCleanup: () -> Void
    @State private var selectedResourceIDs: Set<String> = []
    @State private var cleanupReview: StorageCleanupReviewContext?
    @State private var isAwaitingRepositoryAuthorization = false
    @State private var isCheckingRepositoryAuthorization = false
    @State private var repositoryAuthorizationCheckFailed = false

    private var profile: StorageSourceDetailProfile {
        .profile(for: item.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                StorageSourceBrandIcon(
                    sourceID: item.id,
                    fallbackSymbol: item.candidate.descriptor.symbol
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.candidate.descriptor.title).font(.headline)
                    Text(item.candidate.descriptor.family.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let result = item.result {
                    Text(AgentStorageSizeFormatter.string(result.allocatedBytes))
                        .font(.system(.title3, design: .monospaced, weight: .semibold))
                }
                if isScanning {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("正在等待整体分析结果"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            Divider()

            if let result = item.result {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if item.id == .workspace {
                            repositoryDiscoveryPanel(result: result)
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Text(profile.headline)
                                .font(.title2.weight(.semibold))
                            Text(profile.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 28) {
                                composition(result)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                management
                                    .frame(width: 300, alignment: .topLeading)
                            }
                            VStack(alignment: .leading, spacing: 24) {
                                composition(result)
                                Divider()
                                management
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 1_120, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !selectedRequests(result).isEmpty {
                        cleanupSelectionBar(result)
                    }
                }
            } else if item.id == .workspace {
                repositoryDiscoveryLoading
            } else if isScanning {
                StorageSourceDetailSkeleton(profile: profile)
            } else {
                ContentUnavailableView {
                    Label(L10n.text("当前分析没有此来源的结果"), systemImage: "externaldrive.badge.questionmark")
                } description: {
                    Text(L10n.text("详情页只展示空间地图的整体分析结果，不会单独再次扫描。"))
                } actions: {
                    Button(L10n.text("返回空间地图"), action: goBack)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(item.candidate.descriptor.title)
        .task(id: shouldStartWorkspaceAnalysis) {
            guard shouldStartWorkspaceAnalysis else { return }
            await Task.yield()
            startAnalysis()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard item.id == .workspace, isAwaitingRepositoryAuthorization else { return }
            checkRepositoryAuthorization()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                }
                .help(L10n.text("返回空间地图"))
                .accessibilityLabel(L10n.text("返回空间地图"))
            }
        }
        .sheet(item: $cleanupReview) { context in
            StorageCleanupReviewSheet(
                context: context,
                close: { cleanupReview = nil },
                didFinish: { summary in
                    let succeeded = Set(summary.outcomes.filter(\.succeeded).map(\.id))
                    selectedResourceIDs.subtract(succeeded)
                    if summary.succeededCount > 0 { didCleanup() }
                }
            )
        }
    }

    private var shouldStartWorkspaceAnalysis: Bool {
        item.id == .workspace
            && item.result == nil
            && !isScanning
            && !isFullAnalysisRunning
    }

    private var repositoryDiscoveryLoading: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                repositoryDiscoveryPanel(result: nil)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        if isScanning { ProgressView().controlSize(.small) }
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .foregroundStyle(Color.accentColor)
                        Text(isScanning
                            ? L10n.text("正在定位 Git 仓库与 Worktree")
                            : L10n.text("准备分析 Git 工作区"))
                            .font(.headline)
                    }
                    Text(isScanning
                        ? L10n.text("正在遍历可读磁盘；发现顶层仓库后不会继续下钻其内部目录。")
                        : L10n.text("仓库定位只在本详情中运行，其他应用分析不会被重新执行。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !isScanning {
                        Button(L10n.text("分析 Git 工作区"), systemImage: "arrow.clockwise", action: startAnalysis)
                            .buttonStyle(AppActionButtonStyle(kind: .primary))
                    }
                }
                .padding(.horizontal, 2)
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func repositoryDiscoveryPanel(result: StorageSourceResult?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 14) {
                repositoryDiscoveryIdentity(result: result)
                Spacer(minLength: 18)
                repositoryAuthorizationActions
            }
            VStack(alignment: .leading, spacing: 14) {
                repositoryDiscoveryIdentity(result: result)
                repositoryAuthorizationActions
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-repository-discovery")
    }

    private func repositoryDiscoveryIdentity(result: StorageSourceResult?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: hasFullDiskRepositoryAccess ? "checkmark.shield.fill" : "lock.shield")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(hasFullDiskRepositoryAccess ? Color.green : Color.accentColor)
                .frame(width: 34, height: 34)
                .background(
                    (hasFullDiskRepositoryAccess ? Color.green : Color.accentColor).opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 6)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(repositoryAuthorizationTitle)
                    .font(.callout.weight(.semibold))
                Text(repositoryDiscoveryDetail(result: result))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var repositoryAuthorizationActions: some View {
        if hasFullDiskRepositoryAccess {
            Label(L10n.text("已包含受保护位置"), systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        } else {
            HStack(spacing: 8) {
                if isAwaitingRepositoryAuthorization {
                    Button {
                        openRepositoryAuthorizationSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(AppIconButtonStyle(size: 34))
                    .help(L10n.text("打开完全磁盘访问"))
                }
                Button {
                    isAwaitingRepositoryAuthorization
                        ? checkRepositoryAuthorization()
                        : requestRepositoryAuthorization()
                } label: {
                    Label(
                        authorizationButtonTitle,
                        systemImage: isCheckingRepositoryAuthorization ? "hourglass" : "lock.open"
                    )
                }
                .buttonStyle(AppActionButtonStyle(kind: .primary))
                .disabled(isCheckingRepositoryAuthorization)
            }
        }
    }

    private func repositoryDiscoveryDetail(result: StorageSourceResult?) -> String {
        if repositoryAuthorizationCheckFailed {
            return L10n.text("当前可读磁盘仍会继续分析；受保护目录尚未加入范围。")
        }
        if let result {
            let repositories = result.resourceTree.filter { $0.kind == .repository }.count
            let worktrees = result.resourceTree.reduce(0) { total, node in
                total + node.children.filter { $0.kind == .worktree }.count
            }
            return L10n.format("已识别 %d 个仓库 · %d 个 Worktree", repositories, worktrees)
        }
        return L10n.text("统一定位本机与外接磁盘中的顶层仓库，并解析 Worktree 关系。")
    }

    private func requestRepositoryAuthorization() {
        guard !refreshRepositoryAuthorization() else { return }
        isAwaitingRepositoryAuthorization = true
        repositoryAuthorizationCheckFailed = false
        openRepositoryAuthorizationSettings()
    }

    private func openRepositoryAuthorizationSettings() {
        guard let url = RepositoryAccessAuthorization.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func checkRepositoryAuthorization() {
        guard !isCheckingRepositoryAuthorization else { return }
        isCheckingRepositoryAuthorization = true
        repositoryAuthorizationCheckFailed = false
        Task { @MainActor in
            let delays: [Duration] = [.milliseconds(180), .milliseconds(620), .seconds(1)]
            for delay in delays {
                try? await Task.sleep(for: delay)
                if refreshRepositoryAuthorization() {
                    isAwaitingRepositoryAuthorization = false
                    isCheckingRepositoryAuthorization = false
                    return
                }
            }
            isCheckingRepositoryAuthorization = false
            repositoryAuthorizationCheckFailed = true
        }
    }

    private var repositoryAuthorizationTitle: String {
        if isCheckingRepositoryAuthorization { return L10n.text("正在确认完全磁盘访问") }
        if repositoryAuthorizationCheckFailed { return L10n.text("尚未获得完全磁盘访问") }
        if hasFullDiskRepositoryAccess { return L10n.text("完整仓库范围已启用") }
        return L10n.text("扩展 Git 仓库发现范围")
    }

    private var authorizationButtonTitle: String {
        if isCheckingRepositoryAuthorization { return L10n.text("正在检查授权") }
        return L10n.text(isAwaitingRepositoryAuthorization ? "检查授权" : "打开完全磁盘访问")
    }

    private func composition(_ result: StorageSourceResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(profile.compositionTitle)
                .font(.headline)
            Text(profile.compositionDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            StorageResourceTreeView(
                nodes: resourceNodes(result),
                categoryDescription: profile.categoryDescription,
                selectedIDs: $selectedResourceIDs
            )
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.48))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))

            if let diagnostic = result.inventoryDiagnostic {
                Label(diagnostic, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Label(
                result.isComplete ? L10n.text("本次读取范围完整") : L10n.text("部分位置无法读取，容量可能偏低"),
                systemImage: result.isComplete ? "checkmark.shield" : "exclamationmark.shield"
            )
            .font(.caption)
            .foregroundStyle(result.isComplete ? Color.secondary : Color.orange)
        }
    }

    private func resourceNodes(_ result: StorageSourceResult) -> [StorageResourceNode] {
        guard result.resourceTree.isEmpty else { return result.resourceTree }
        return StorageComponentPresentation.aggregate(result.components).map { component in
            StorageResourceNode(
                id: component.id,
                kind: .category,
                title: component.title,
                detail: component.rootDisplayName,
                symbol: component.risk.symbol,
                allocatedBytes: component.allocatedBytes,
                logicalBytes: component.logicalBytes,
                entryCount: component.entryCount,
                risk: component.risk,
                evidence: component.evidence,
                isProtected: component.isProtected
            )
        }
    }

    private func selectedRequests(_ result: StorageSourceResult) -> [StorageCleanupRequest] {
        StorageResourceTreeProjection.selectedRequests(
            nodes: resourceNodes(result),
            selectedIDs: selectedResourceIDs
        )
    }

    private func cleanupSelectionBar(_ result: StorageSourceResult) -> some View {
        let requests = selectedRequests(result)
        let bytes = requests.reduce(UInt64.zero) { $0.addingClamped($1.displayBytes) }
        return HStack(spacing: 12) {
            Image(systemName: "checkmark.square.fill")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.format("已选择 %d 项", requests.count))
                    .font(.callout.weight(.semibold))
                Text(AgentStorageSizeFormatter.string(bytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.text("清除选择")) { selectedResourceIDs.removeAll() }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))
            Button {
                cleanupReview = StorageCleanupReviewContext(
                    sourceTitle: item.candidate.descriptor.title,
                    sourceID: item.id,
                    requests: requests
                )
            } label: {
                Label(L10n.text("检查并清理"), systemImage: "trash")
            }
            .buttonStyle(AppActionButtonStyle(kind: .primary))
        }
        .padding(.horizontal, 18)
        .frame(height: 70)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var management: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(profile.managementTitle, systemImage: "checklist")
                .font(.headline)
            Text(profile.managementDetail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action = profile.officialAction {
                Button {
                    NSWorkspace.shared.open(action.url)
                } label: {
                    Label(action.title, systemImage: "arrow.up.right.square")
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))
            }
            Divider()
            Label(L10n.text("分析阶段只读；只有带复选框的资源可在确认后清理。"), systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StorageSourceDetailSkeleton: View {
    let profile: StorageSourceDetailProfile

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(profile.headline)
                        .font(.title2.weight(.semibold))
                    Text(profile.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        skeletonComposition
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        skeletonManagement
                            .frame(width: 300, alignment: .topLeading)
                    }
                    VStack(alignment: .leading, spacing: 24) {
                        skeletonComposition
                        Divider()
                        skeletonManagement
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1_120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("正在等待整体分析结果"))
    }

    private var skeletonComposition: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(profile.compositionTitle).font(.headline)
            Text(profile.compositionDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { index in
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 9) {
                        RoundedRectangle(cornerRadius: 3).frame(width: 150, height: 16)
                        RoundedRectangle(cornerRadius: 3).frame(height: 5)
                        RoundedRectangle(cornerRadius: 3).frame(width: 250, height: 11)
                    }
                    .foregroundStyle(Color.secondary.opacity(0.16))
                    .padding(14)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .accessibilityHidden(true)
    }

    private var skeletonManagement: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(profile.managementTitle, systemImage: "checklist")
                .font(.headline)
            Text(profile.managementDetail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Label(L10n.text("整体分析完成后自动显示结果"), systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}

private enum StorageComponentPresentation {
    static func aggregate(_ components: [StorageComponent]) -> [StorageComponent] {
        Dictionary(grouping: components, by: \.title)
            .map { title, group in
                StorageComponent(
                    id: title,
                    title: title,
                    rootDisplayName: L10n.format("%d 个已知位置", Set(group.map(\.rootDisplayName)).count),
                    allocatedBytes: group.reduce(0) { $0.addingClamped($1.allocatedBytes) },
                    logicalBytes: group.reduce(0) { $0.addingClamped($1.logicalBytes) },
                    entryCount: group.reduce(0) { $0 + $1.entryCount },
                    newestModificationDate: group.compactMap(\.newestModificationDate).max(),
                    risk: group.map(\.risk).max() ?? .protectedUserData,
                    isProtected: group.contains(where: \.isProtected)
                )
            }
            .sorted { lhs, rhs in
                if lhs.allocatedBytes != rhs.allocatedBytes { return lhs.allocatedBytes > rhs.allocatedBytes }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }
}

private struct StorageComponentAnalysisRow: View {
    let component: StorageComponent
    let totalBytes: UInt64
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(L10n.text(component.title), systemImage: component.risk.symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(component.risk.color)
                Spacer(minLength: 16)
                Text(AgentStorageSizeFormatter.string(component.allocatedBytes))
                    .font(.system(.body, design: .monospaced, weight: .semibold))
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(nsColor: .separatorColor).opacity(0.45))
                    Capsule()
                        .fill(component.risk.color.opacity(0.75))
                        .frame(width: max(3, proxy.size.width * share))
                }
            }
            .frame(height: 5)
            HStack(alignment: .top, spacing: 10) {
                Text(detail)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Text(L10n.format("%.0f%%", share * 100))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var share: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(component.allocatedBytes) / Double(totalBytes))
    }
}

private extension UInt64 {
    func addingClamped(_ other: UInt64) -> UInt64 {
        let result = addingReportingOverflow(other)
        return result.overflow ? .max : result.partialValue
    }
}

private extension StorageSourceFamily {
    var title: String {
        switch self {
        case .applications: L10n.text("应用与浏览器")
        case .developerTools: L10n.text("开发工具")
        case .containers: L10n.text("容器")
        case .aiTools: L10n.text("AI 工具")
        case .workspaces: L10n.text("工作区")
        }
    }

    var color: Color {
        switch self {
        case .applications: .cyan
        case .developerTools: .green
        case .containers: .orange
        case .aiTools: .pink
        case .workspaces: .secondary
        }
    }
}

private extension StorageRiskLevel {
    var title: String {
        switch self {
        case .rebuildableCache: L10n.text("可重建缓存")
        case .sharedOrExpensive: L10n.text("共享或重建成本较高")
        case .environmentOrRuntime: L10n.text("环境或运行对象")
        case .protectedUserData: L10n.text("受保护数据")
        }
    }

    var symbol: String {
        switch self {
        case .rebuildableCache: "arrow.triangle.2.circlepath"
        case .sharedOrExpensive: "shippingbox"
        case .environmentOrRuntime: "gearshape.2"
        case .protectedUserData: "lock.shield"
        }
    }

    var color: Color {
        switch self {
        case .rebuildableCache: .green
        case .sharedOrExpensive: .orange
        case .environmentOrRuntime: .secondary
        case .protectedUserData: .red
        }
    }
}
