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

    var family: StorageSourceFamily? {
        switch self {
        case .all: nil
        case .applications: .applications
        case .developerTools: .developerTools
        case .containers: .containers
        case .aiTools: .aiTools
        case .workspaces: .workspaces
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
    case safeCleanup
    case source(StorageSourceID)
    case agentAnalysis(AgentStorageProvider)
}

enum StorageMapOverviewPresentation: Equatable {
    case discovery
    case noSources
    case firstRun
    case analysis

    static func resolve(
        isDetecting: Bool,
        isPendingAutomaticAnalysis: Bool,
        hasCandidates: Bool,
        hasUnifiedResults: Bool,
        isFullAnalysisRunning: Bool
    ) -> Self {
        if isDetecting || isPendingAutomaticAnalysis { return .discovery }
        if !hasCandidates { return .noSources }
        if !hasUnifiedResults, !isFullAnalysisRunning { return .firstRun }
        return .analysis
    }
}

private struct StorageMapSourcePresentation: Identifiable {
    let candidate: StorageSourceCandidate
    let result: StorageSourceResult?
    let resultRevision: UInt64
    let activity: StorageSourceActivityPresentation
    let compositionSummary: String?
    let displayBytes: UInt64

    var id: StorageSourceID { candidate.id }
}

struct StorageMapView: View {
    let model: StorageMapModel
    let agentStorage: AgentStorageModel
    let nodeRuntime: ClaudeNodeRuntimeStatusModel

    @State private var route: StorageMapRoute = .overview
    @State private var scope: StorageMapScope = .all
    @State private var renderedScope: StorageMapScope = .all
    @State private var displayedSourceOrder: [StorageSourceID] = []
    @State private var overviewCleanupIndex = StorageSafeCleanupIndex.empty
    @State private var scopeUpdateTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch route {
            case .overview:
                overview
            case .safeCleanup:
                safeCleanup
            case .source(let sourceID):
                sourceDetail(sourceID)
            case .agentAnalysis(let provider):
                agentAnalysis(provider: provider)
            }
        }
        .task {
            await model.prepare()
            guard !Task.isCancelled else { return }
            synchronizeDisplayedOrder(animated: false)
            if shouldStartInitialAnalysis {
                startFullAnalysis()
            }
        }
        .task(id: model.snapshot?.id) {
            guard let snapshot = model.snapshot else {
                overviewCleanupIndex = .empty
                return
            }
            await Task.yield()
            let index = await Task.detached(priority: .userInitiated) {
                StorageSafeCleanupIndex(snapshot: snapshot)
            }.value
            guard !Task.isCancelled else { return }
            overviewCleanupIndex = index
        }
        .onChange(of: scope) { _, newScope in
            scopeUpdateTask?.cancel()
            scopeUpdateTask = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled else { return }
                renderedScope = newScope
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
            ZStack {
                switch overviewPresentation {
                case .discovery:
                    detectorLoading
                        .transition(.opacity)
                case .noSources:
                    noSources
                        .transition(.opacity)
                case .firstRun:
                    StorageMapFirstRunView(
                        candidates: model.candidates,
                        errorMessage: model.errorMessage,
                        startAnalysis: startFullAnalysis
                    )
                    .transition(.opacity)
                case .analysis:
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            StorageMapSummaryBand(
                                model: model,
                                isAgentScanning: agentStorage.isScanning,
                                safeCleanupBytes: overviewCleanupIndex.totalBytes,
                                hasSafeCleanup: !overviewCleanupIndex.groups.isEmpty,
                                startAnalysis: startFullAnalysis,
                                stopAnalysis: stopFullAnalysis,
                                openSafeCleanup: { route = .safeCleanup }
                            )
                            Divider()
                            Section {
                                sourceWorkspace(width: proxy.size.width)
                            } header: {
                                VStack(spacing: 0) {
                                    scopeBar
                                    Divider()
                                }
                                .background(InstrumentDesign.Palette.canvas)
                            }
                        }
                    }
                    .scrollIndicators(.visible)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .background(InstrumentDesign.Palette.canvas)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.24),
                value: overviewPresentation
            )
        }
    }

    private var overviewPresentation: StorageMapOverviewPresentation {
        StorageMapOverviewPresentation.resolve(
            isDetecting: model.phase == .detecting,
            isPendingAutomaticAnalysis: shouldStartInitialAnalysis,
            hasCandidates: !model.candidates.isEmpty,
            hasUnifiedResults: hasUnifiedResults,
            isFullAnalysisRunning: isFullAnalysisRunning
        )
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
            Text(L10n.text("来源分类"))
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)

            Picker(L10n.text("来源分类"), selection: $scope) {
                ForEach(StorageMapScope.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 156, height: 30, alignment: .leading)
            .background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: InstrumentDesign.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: InstrumentDesign.Radius.control)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: InstrumentDesign.Stroke.hairline)
            }
            Spacer(minLength: 8)
            if model.snapshot != nil {
                HStack(spacing: 14) {
                    if hasSafeCleanupForOverview {
                        Button { route = .safeCleanup } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.shield.fill")
                                Text(L10n.text("安全清理"))
                                Text(safeCleanupValueForOverview)
                                    .monospacedDigit()
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(InstrumentDesign.ColorRole.cleanup)
                            .padding(.horizontal, 9)
                            .frame(height: 28)
                            .background(InstrumentDesign.ColorRole.cleanup.opacity(0.11), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .help(L10n.text("查看可安全清理的缓存"))
                        .accessibilityIdentifier("storage-map-safe-cleanup-scope")
                    }
                    Text(L10n.format("%d 个来源", visibleItems.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private var hasSafeCleanupForOverview: Bool {
        !overviewCleanupIndex.groups.isEmpty
    }

    private var safeCleanupValueForOverview: String {
        AgentStorageSizeFormatter.string(
            overviewCleanupIndex.totalBytes
        )
    }

    private func sourceWorkbench(width: CGFloat) -> some View {
        let items = visibleItems
        let safeBytesBySource = Dictionary(
            uniqueKeysWithValues: overviewCleanupIndex.groups.map {
                ($0.id, $0.totalBytes)
            }
        )
        return LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().padding(.leading, 72) }
                let openAvailability = resultAccess(for: item.id)
                StorageSourceWorkbenchRow(
                    item: item,
                    activity: item.activity,
                    displayBytes: item.displayBytes,
                    safeCleanupBytes: safeBytesBySource[item.id] ?? 0,
                    usesCompactLayout: width < 820,
                    canReanalyze: canReanalyze(item.id),
                    openAvailability: openAvailability,
                    unavailableMessage: unavailableMessage(
                        for: item.id,
                        access: openAvailability
                    ),
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
        .glassSurface(padding: 0)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
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

    private var safeCleanup: some View {
        StorageSafeCleanupView(
            snapshot: model.snapshot,
            initialProjection: overviewCleanupIndex,
            isRefreshing: isAnyAnalysisRunning,
            resultRevisionsBySource: model.resultRevisionsBySource,
            refreshErrorsBySource: model.refreshErrorsBySource,
            goBack: { route = .overview },
            reanalyze: { sourceIDs in
                for sourceID in sourceIDs { model.refreshAfterCleanup(sourceID: sourceID) }
            }
        )
    }

    @ViewBuilder
    private func sourceDetail(_ sourceID: StorageSourceID) -> some View {
        if let item = item(for: sourceID) {
            StorageSourceDetailView(
                item: item,
                isScanning: isScanning(sourceID),
                refreshError: model.refreshErrorsBySource[sourceID],
                isFullAnalysisRunning: isFullAnalysisRunning,
                hasFullDiskRepositoryAccess: model.hasFullDiskRepositoryAccess,
                startAnalysis: { model.startAnalysis(sourceID: sourceID) },
                refreshRepositoryAuthorization: model.refreshRepositoryAuthorization,
                goBack: { route = .overview },
                didCleanup: { model.refreshAfterCleanup(sourceID: sourceID) }
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
            providerExitAction: { route = .overview },
            cleanupDidAffectProviders: { providers in
                for provider in providers {
                    model.refreshAfterCleanup(sourceID: provider.storageSourceID)
                }
            }
        )
    }

    @discardableResult
    private func openSource(_ sourceID: StorageSourceID) -> String? {
        let access = resultAccess(for: sourceID)
        guard access.canPresent else {
            return unavailableMessage(for: sourceID, access: access)
        }
        switch StorageSourceDestination.destination(for: sourceID) {
        case .tailoredAnalysis:
            route = .source(sourceID)
        case .agentAnalysis(let provider):
            route = .agentAnalysis(provider)
        }
        return nil
    }

    private func resultAccess(for sourceID: StorageSourceID) -> StorageSourceResultAccess {
        if sourceID == .workspace,
           model.candidates.contains(where: { $0.id == .workspace }) {
            return .available
        }
        return StorageSourceResultAccess.resolve(
            sourceID: sourceID,
            storageSnapshot: model.snapshot,
            agentSnapshot: agentStorage.snapshot
        )
    }

    private func unavailableMessage(
        for sourceID: StorageSourceID,
        access: StorageSourceResultAccess
    ) -> String {
        let reason: String
        switch access {
        case .available:
            return L10n.text("查看专属分析")
        case .storageResultRequired:
            reason = model.isAnalyzingSource(sourceID)
                ? L10n.text("正在测量文件分配")
                : L10n.text("当前分析没有此来源的结果")
        case .agentResultRequired(let provider):
            reason = agentStorage.isAnalyzing(provider)
                ? L10n.format("正在等待 %@ 深度分析", provider.displayName)
                : L10n.text("当前分析没有此来源的结果")
        }
        return L10n.format("详情尚未就绪：%@", reason)
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
            .filter { renderedScope.includes($0.descriptor.family) }
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
            resultRevision: model.resultRevision(for: candidate.id),
            activity: activity,
            compositionSummary: agentSummary(for: candidate.id)
                .flatMap(StorageSourceActivityPresentation.completedAgentComposition)
                ?? result.flatMap(StorageSourceActivityPresentation.completedComposition),
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
                    Text(L10n.text(candidate.descriptor.title))
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
                                Text(L10n.text(candidate.descriptor.title))
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
    let safeCleanupBytes: UInt64
    let usesCompactLayout: Bool
    let canReanalyze: Bool
    let openAvailability: StorageSourceResultAccess
    let unavailableMessage: String
    let open: () -> String?
    let reanalyze: () -> Void

    @State private var isHovering = false
    @State private var isOpening = false
    @State private var accessFeedback: String?
    @State private var openTask: Task<Void, Never>?
    @State private var feedbackTask: Task<Void, Never>?

    var body: some View {
        Button(action: requestOpen) {
            HStack(spacing: 10) {
                Group {
                    if usesCompactLayout {
                        compactContent
                    } else {
                        wideContent
                    }
                }
                .contentShape(Rectangle())
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()

                Color.clear
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)

                Group {
                    if isOpening {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 12, height: 16)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: usesCompactLayout ? 94 : 76)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(openAvailability.canPresent
            ? L10n.text("查看专属分析")
            : unavailableMessage)
        .background(rowBackground)
        .overlay(alignment: .trailing) {
            reanalysisControl
                .padding(.trailing, 36)
        }
        .onHover { isHovering = $0 }
        .onChange(of: openAvailability) { _, access in
            if access.canPresent {
                feedbackTask?.cancel()
                accessFeedback = nil
            }
        }
        .onChange(of: unavailableMessage) { _, message in
            if accessFeedback != nil { accessFeedback = message }
        }
        .onDisappear {
            openTask?.cancel()
            feedbackTask?.cancel()
        }
        .accessibilityElement(children: .contain)
    }

    private var wideContent: some View {
        HStack(spacing: 18) {
            identity
                .frame(minWidth: 185, idealWidth: 220, maxWidth: 260, alignment: .leading)
            activityContent
                .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
            metrics
                .frame(width: 300, alignment: .trailing)
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private var identity: some View {
        HStack(spacing: 12) {
            StorageSourceBrandIcon(sourceID: item.id, fallbackSymbol: item.candidate.descriptor.symbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text(item.candidate.descriptor.title))
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
            if let accessFeedback {
                Label(accessFeedback, systemImage: "exclamationmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .transition(.opacity)
            } else if activity.state == .active || activity.state == .queued || activity.state == .ready {
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
            }
            if accessFeedback != nil {
                EmptyView()
            } else if let composition = completedComposition {
                Text(composition)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(activity.workDetail)
                    .font(activity.state == .complete || activity.state == .partial
                        ? .callout.weight(.medium)
                        : .caption)
                    .foregroundStyle(activity.state == .complete ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if accessFeedback == nil, let supportingDetail = activity.supportingDetail {
                Text(supportingDetail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var completedComposition: String? {
        guard activity.state == .complete || activity.state == .partial else { return nil }
        return item.compositionSummary
    }

    private var metrics: some View {
        HStack(spacing: 18) {
            Text(AgentStorageSizeFormatter.string(displayBytes))
                .font(.system(.callout, design: .monospaced, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.28), value: displayBytes)
            if safeCleanupBytes > 0 {
                Text(L10n.format(
                    "可安全清理 %@",
                    AgentStorageSizeFormatter.string(safeCleanupBytes)
                ))
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(Color.teal)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
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
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
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
                .allowsHitTesting(false)
        case .hidden:
            Color.clear
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }

    private var rowBackground: Color {
        if isOpening { return Color.accentColor.opacity(0.1) }
        if accessFeedback != nil { return Color.orange.opacity(0.075) }
        if isHovering { return Color.primary.opacity(0.055) }
        return .clear
    }

    private func requestOpen() {
        guard openTask == nil else { return }
        guard openAvailability.canPresent else {
            presentAccessFeedback(unavailableMessage)
            return
        }

        feedbackTask?.cancel()
        accessFeedback = nil
        isOpening = true
        openTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard let failureMessage = open() else { return }
            isOpening = false
            openTask = nil
            presentAccessFeedback(failureMessage)
        }
    }

    private func presentAccessFeedback(_ message: String) {
        feedbackTask?.cancel()
        withAnimation(.easeOut(duration: 0.16)) {
            accessFeedback = message
        }
        feedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                accessFeedback = nil
            }
            feedbackTask = nil
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
        values[.vscode] = applicationIcon(
            bundleIdentifiers: ["com.microsoft.VSCode"],
            paths: ["/Applications/Visual Studio Code.app"]
        )
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

private struct StorageSafeCleanupView: View {
    let snapshot: StorageAnalysisSnapshot?
    let isRefreshing: Bool
    let resultRevisionsBySource: [StorageSourceID: UInt64]
    let refreshErrorsBySource: [StorageSourceID: String]
    let goBack: () -> Void
    let reanalyze: (Set<StorageSourceID>) -> Void

    @State private var scope: StorageMapScope = .all
    @State private var renderedScope: StorageMapScope = .all
    @State private var projection = StorageSafeCleanupIndex.empty
    @State private var selectedIDs = Set<String>()
    @State private var expandedSourceIDs = Set<StorageSourceID>()
    @State private var renderedExpandedSourceIDs = Set<StorageSourceID>()
    @State private var didInitializeSelection = false
    @State private var isExecuting = false
    @State private var currentRequestID: String?
    @State private var outcomesByID: [String: StorageCleanupOutcome] = [:]
    @State private var executionTask: Task<Void, Never>?
    @State private var scopeUpdateTask: Task<Void, Never>?
    @State private var expansionUpdateTask: Task<Void, Never>?
    @State private var isPreparingProjection = false

    init(
        snapshot: StorageAnalysisSnapshot?,
        initialProjection: StorageSafeCleanupIndex,
        isRefreshing: Bool,
        resultRevisionsBySource: [StorageSourceID: UInt64],
        refreshErrorsBySource: [StorageSourceID: String],
        goBack: @escaping () -> Void,
        reanalyze: @escaping (Set<StorageSourceID>) -> Void
    ) {
        self.snapshot = snapshot
        self.isRefreshing = isRefreshing
        self.resultRevisionsBySource = resultRevisionsBySource
        self.refreshErrorsBySource = refreshErrorsBySource
        self.goBack = goBack
        self.reanalyze = reanalyze
        _projection = State(initialValue: initialProjection)
        _selectedIDs = State(initialValue: initialProjection.allRequestIDs)
        _didInitializeSelection = State(initialValue: !initialProjection.allRequestIDs.isEmpty)
        if let firstSourceID = initialProjection.groups.first?.id {
            _expandedSourceIDs = State(initialValue: [firstSourceID])
            _renderedExpandedSourceIDs = State(initialValue: [firstSourceID])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            scopeBar
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(L10n.text("安全清理"))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: goBack) { Image(systemName: "chevron.left") }
                    .disabled(isExecuting)
                    .help(L10n.text("返回空间地图"))
                    .accessibilityLabel(L10n.text("返回空间地图"))
            }
        }
        .task(id: snapshot?.id) { await prepareProjection() }
        .onChange(of: scope) { _, newScope in
            scopeUpdateTask?.cancel()
            scopeUpdateTask = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled else { return }
                renderedScope = newScope
            }
        }
        .onChange(of: availableScopes.map(\.id)) { _, scopes in
            guard scopes.contains(scope.id) else {
                scope = .all
                return
            }
        }
        .onChange(of: resultRevisionsBySource) { oldValue, newValue in
            let updatedSourceIDs = Set(newValue.keys).filter {
                newValue[$0] != oldValue[$0]
            }
            outcomesByID = outcomesByID.filter { requestID, _ in
                guard let sourceID = projection.sourceIDByRequestID[requestID] else { return false }
                return !updatedSourceIDs.contains(sourceID)
            }
        }
        .onDisappear {
            executionTask?.cancel()
            scopeUpdateTask?.cancel()
            expansionUpdateTask?.cancel()
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                cleanupIdentity
                Spacer(minLength: 20)
                selectionSummary
                cleanupButton
            }
            VStack(alignment: .leading, spacing: 16) {
                cleanupIdentity
                HStack(spacing: 12) {
                    selectionSummary
                    Spacer(minLength: 8)
                    cleanupButton
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var cleanupIdentity: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("安全清理"))
                .font(.title2.weight(.semibold))
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.teal)
                Text(AgentStorageSizeFormatter.string(projection.totalBytes))
                    .font(.system(size: 34, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Text(L10n.text("仅包含可重建缓存；发生变化的项目会自动跳过。"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var selectionSummary: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(L10n.format("已选 %@", AgentStorageSizeFormatter.string(selectedBytes)))
                .font(.callout.weight(.semibold).monospacedDigit())
            Text(L10n.format("%d 个项目", selectedIDs.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var cleanupButton: some View {
        Button(action: executeSelected) {
            HStack(spacing: 8) {
                if isExecuting { ProgressView().controlSize(.small) }
                Image(systemName: isExecuting ? "trash.slash" : "trash")
                Text(isExecuting ? L10n.text("正在清理") : L10n.text("移到废纸篓"))
            }
        }
        .buttonStyle(AppActionButtonStyle(kind: .primary, size: .large))
        .disabled(selectedEntries.isEmpty || isExecuting)
        .accessibilityIdentifier("storage-safe-cleanup-execute")
    }

    private var scopeBar: some View {
        ZStack {
            Picker(L10n.text("来源分类"), selection: $scope) {
                ForEach(availableScopes) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 620)
            .disabled(isExecuting)
            HStack {
                Spacer(minLength: 0)
                if isRefreshing {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("正在刷新"))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if let refreshErrorSummary {
                    HStack(spacing: 7) {
                        Label(refreshErrorSummary, systemImage: "exclamationmark.triangle.fill")
                            .lineLimit(1)
                            .help(refreshErrorSummary)
                        Button {
                            reanalyze(Set(refreshErrorsBySource.keys))
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .help(L10n.text("重试同步"))
                        .accessibilityLabel(L10n.text("重试同步"))
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    Text(L10n.format("%d 个项目", visibleRequestIDs.count))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 54)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        if projection.groups.isEmpty && isPreparingProjection {
            VStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(L10n.text("正在准备清理项目"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else if projection.groups.isEmpty {
            ContentUnavailableView {
                Label(L10n.text("当前没有可安全清理的缓存"), systemImage: "checkmark.shield")
            } description: {
                Text(L10n.text("只有经过验证的可重建缓存才会显示在这里。"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleGroups.isEmpty {
            ContentUnavailableView {
                Label(L10n.text("此分类没有可安全清理的缓存"), systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(L10n.text("切换到其他来源分类查看可清理项目。"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    HStack {
                        Text(L10n.text("清理项目"))
                            .font(.headline)
                        Spacer()
                        Button(visibleSelectionIsComplete
                            ? L10n.text("取消选择当前分类")
                            : L10n.text("选择当前分类")) {
                            toggleVisibleSelection()
                        }
                        .buttonStyle(.link)
                        .disabled(isExecuting)
                    }
                    .padding(.horizontal, 24)
                    .frame(height: 48)

                    ForEach(visibleGroups) { group in
                        groupView(group)
                        if group.id != visibleGroups.last?.id { Divider().padding(.leading, 66) }
                    }
                }
                .padding(.bottom, 20)
            }
            .scrollIndicators(.visible)
        }
    }

    private func groupView(_ group: StorageSafeCleanupGroup) -> some View {
        let allGroupIDs = projection.requestIDsByGroup[group.id] ?? []
        let groupIDs = allGroupIDs.subtracting(succeededRequestIDs)
        let selectedCount = selectedIDs.intersection(groupIDs).count
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                if groupIDs.isEmpty, !allGroupIDs.isEmpty {
                    pendingSynchronizationIndicator
                } else {
                    selectionButton(
                        selectedCount: selectedCount,
                        totalCount: groupIDs.count,
                        accessibilityLabel: L10n.format("选择 %@", group.title)
                    ) {
                        toggleSelection(groupIDs)
                    }
                }
                StorageSourceBrandIcon(sourceID: group.id, fallbackSymbol: group.symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title).font(.callout.weight(.semibold))
                    Text(group.family.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Text(AgentStorageSizeFormatter.string(group.totalBytes))
                    .font(.system(.callout, design: .monospaced, weight: .semibold))
                Button {
                    toggleGroupExpansion(group.id)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(expandedSourceIDs.contains(group.id) ? 90 : 0))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isExecuting)
                .accessibilityLabel(expandedSourceIDs.contains(group.id)
                    ? L10n.text("收起清理项目")
                    : L10n.text("展开清理项目"))
            }
            .padding(.horizontal, 24)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isExecuting else { return }
                toggleGroupExpansion(group.id)
            }

            if renderedExpandedSourceIDs.contains(group.id) {
                ForEach(group.requests) { request in
                    Divider().padding(.leading, 86)
                    requestView(request)
                }
            }
        }
    }

    private func requestView(_ request: StorageCleanupRequest) -> some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.5))
                .frame(width: 1, height: 44)
                .padding(.leading, 42)
            if outcomesByID[request.id]?.succeeded == true {
                pendingSynchronizationIndicator
            } else {
                selectionButton(
                    selectedCount: selectedIDs.contains(request.id) ? 1 : 0,
                    totalCount: 1,
                    accessibilityLabel: L10n.format("选择 %@", L10n.text(request.title))
                ) {
                    toggleSelection([request.id])
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(request.title))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let outcome = outcomesByID[request.id] {
                    Text(outcome.succeeded
                        ? L10n.text("已清理，等待同步确认")
                        : outcome.errorDescription ?? L10n.text("操作失败"))
                        .font(.caption)
                        .foregroundStyle(outcome.succeeded ? Color.green : Color.orange)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if currentRequestID == request.id {
                ProgressView().controlSize(.small)
            } else if let outcome = outcomesByID[request.id] {
                Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(outcome.succeeded ? Color.green : Color.orange)
            }
            Text(AgentStorageSizeFormatter.string(request.displayBytes))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 112, alignment: .trailing)
        }
        .padding(.horizontal, 24)
        .frame(minHeight: 56)
    }

    private func selectionButton(
        selectedCount: Int,
        totalCount: Int,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: selectionSymbol(selectedCount: selectedCount, totalCount: totalCount))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(selectedCount == 0 ? Color.secondary : Color.accentColor)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .disabled(isExecuting)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(selectionValue(selectedCount: selectedCount, totalCount: totalCount))
    }

    private var visibleGroups: [StorageSafeCleanupGroup] {
        projection.groups(for: renderedScope.family)
    }

    private var availableScopes: [StorageMapScope] {
        let families = Set(projection.groupsByFamily.keys)
        return [.all] + StorageMapScope.allCases.filter { item in
            guard let family = item.family else { return false }
            return families.contains(family)
        }
    }

    private var visibleRequestIDs: Set<String> {
        projection.requestIDs(for: renderedScope.family).subtracting(succeededRequestIDs)
    }

    private var succeededRequestIDs: Set<String> {
        Set(outcomesByID.values.filter(\.succeeded).map(\.id))
    }

    private var refreshErrorSummary: String? {
        let visibleSourceIDs = Set(projection.groups.map(\.id))
        let messages = refreshErrorsBySource
            .filter { visibleSourceIDs.contains($0.key) }
            .values
            .sorted()
        guard !messages.isEmpty else { return nil }
        return messages.joined(separator: " · ")
    }

    private var pendingSynchronizationIndicator: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Color.green)
            .frame(width: 22, height: 22)
            .help(L10n.text("已清理，等待同步确认"))
            .accessibilityLabel(L10n.text("已清理，等待同步确认"))
    }

    private var visibleSelectionIsComplete: Bool {
        !visibleRequestIDs.isEmpty && visibleRequestIDs.isSubset(of: selectedIDs)
    }

    private var selectedBytes: UInt64 {
        projection.selectedBytes(for: selectedIDs.subtracting(succeededRequestIDs))
    }

    private var selectedEntries: [(StorageSourceID, StorageCleanupRequest)] {
        projection.selectedEntries(for: selectedIDs.subtracting(succeededRequestIDs))
    }

    @MainActor
    private func prepareProjection() async {
        guard let snapshot else {
            projection = .empty
            selectedIDs.removeAll()
            isPreparingProjection = false
            return
        }
        isPreparingProjection = projection.groups.isEmpty
        await Task.yield()
        let newProjection = await Task.detached(priority: .userInitiated) {
            StorageSafeCleanupIndex(snapshot: snapshot)
        }.value
        guard !Task.isCancelled else { return }
        projection = newProjection
        if didInitializeSelection {
            selectedIDs.formIntersection(newProjection.allRequestIDs)
        } else if !newProjection.allRequestIDs.isEmpty {
            selectedIDs = newProjection.allRequestIDs
            didInitializeSelection = true
            if let first = newProjection.groups.first {
                expandedSourceIDs.insert(first.id)
                renderedExpandedSourceIDs.insert(first.id)
            }
        }
        if !availableScopes.contains(where: { $0.id == scope.id }) {
            scope = .all
            renderedScope = .all
        }
        isPreparingProjection = false
    }

    private func toggleGroupExpansion(_ sourceID: StorageSourceID) {
        withAnimation(.snappy(duration: 0.2)) {
            if expandedSourceIDs.contains(sourceID) {
                expandedSourceIDs.remove(sourceID)
            } else {
                expandedSourceIDs.insert(sourceID)
            }
        }
        let requestedExpansion = expandedSourceIDs
        expansionUpdateTask?.cancel()
        expansionUpdateTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, requestedExpansion == expandedSourceIDs else { return }
            withAnimation(.snappy(duration: 0.2)) {
                renderedExpandedSourceIDs = requestedExpansion
            }
        }
    }

    private func toggleVisibleSelection() {
        if visibleSelectionIsComplete {
            selectedIDs.subtract(visibleRequestIDs)
        } else {
            selectedIDs.formUnion(visibleRequestIDs)
        }
    }

    private func toggleSelection(_ ids: Set<String>) {
        let actionableIDs = ids.subtracting(succeededRequestIDs)
        if actionableIDs.isSubset(of: selectedIDs) {
            selectedIDs.subtract(actionableIDs)
        } else {
            selectedIDs.formUnion(actionableIDs)
        }
    }

    private func selectionSymbol(selectedCount: Int, totalCount: Int) -> String {
        if selectedCount == 0 { return "square" }
        if selectedCount == totalCount { return "checkmark.square.fill" }
        return "minus.square.fill"
    }

    private func selectionValue(selectedCount: Int, totalCount: Int) -> String {
        if selectedCount == 0 { return L10n.text("未选择") }
        if selectedCount == totalCount { return L10n.text("已选择") }
        return L10n.text("部分选择")
    }

    private func executeSelected() {
        let entries = selectedEntries
        guard !entries.isEmpty, !isExecuting else { return }
        isExecuting = true
        for (_, request) in entries {
            outcomesByID.removeValue(forKey: request.id)
        }
        executionTask?.cancel()
        executionTask = Task {
            await Task.yield()
            guard !entries.isEmpty, !Task.isCancelled else {
                isExecuting = false
                return
            }
            let executor = StorageResourceCleanupExecutor()
            var succeededIDs = Set<String>()
            var attemptedSourceIDs = Set<StorageSourceID>()
            for (sourceID, request) in entries {
                guard !Task.isCancelled else { break }
                attemptedSourceIDs.insert(sourceID)
                currentRequestID = request.id
                let summary = await executor.execute([request])
                guard let outcome = summary.outcomes.first else { continue }
                outcomesByID[request.id] = outcome
                if outcome.succeeded {
                    succeededIDs.insert(request.id)
                }
            }
            currentRequestID = nil
            isExecuting = false
            selectedIDs.subtract(succeededIDs)
            if !attemptedSourceIDs.isEmpty { reanalyze(attemptedSourceIDs) }
        }
    }
}

private struct StorageMapSummaryBand: View {
    let model: StorageMapModel
    let isAgentScanning: Bool
    let safeCleanupBytes: UInt64
    let hasSafeCleanup: Bool
    let startAnalysis: () -> Void
    let stopAnalysis: () -> Void
    let openSafeCleanup: () -> Void

    @State private var isSafeCleanupHovering = false
    @State private var isAnalysisHovering = false
    @State private var stopFlowAngle: Double = -42

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
        .padding(.vertical, 16)
        .accessibilityElement(children: .contain)
    }

    private var wideSummary: some View {
        HStack(spacing: 12) {
            primarySummary
                .frame(minWidth: 170, alignment: .leading)
            summaryDivider
            HStack(spacing: 16) {
                summaryMetric(L10n.text("来源"), sourceCount)
                summaryMetric(L10n.text("文件条目"), entryCount)
                summaryMetric(L10n.text("磁盘卷"), volumeCount)
            }
            Spacer(minLength: 8)
            actionGroup
                .frame(width: hasSafeCleanup ? 378 : 184, height: 58, alignment: .trailing)
        }
    }

    private var compactSummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                primarySummary
                Spacer(minLength: 0)
            }
            HStack(spacing: 16) {
                summaryMetric(L10n.text("来源"), sourceCount)
                summaryMetric(L10n.text("文件条目"), entryCount)
                summaryMetric(L10n.text("磁盘卷"), volumeCount)
            }
            ViewThatFits(in: .horizontal) {
                actionGroup
                    .frame(maxWidth: .infinity)

                VStack(spacing: 8) {
                    analysisButton
                    if hasSafeCleanup {
                        safeCleanupAction
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var actionGroup: some View {
        if hasSafeCleanup {
            HStack(spacing: 10) {
                analysisButton
                safeCleanupAction
            }
        } else {
            analysisButton
        }
    }

    private var primarySummary: some View {
        VStack(alignment: .leading, spacing: 5) {
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
            .frame(width: 1, height: 64)
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
        .frame(minWidth: 66, alignment: .leading)
    }

    private var safeCleanupAction: some View {
        Button(action: openSafeCleanup) {
            HStack(spacing: 11) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 21, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text("可安全清理"))
                        .font(.callout.weight(.semibold))
                    Text(safeCleanupValue)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(InstrumentDesign.ColorRole.cleanup)
            .padding(.horizontal, 14)
            .frame(minWidth: 0, idealWidth: 178, maxWidth: 184)
            .frame(
                width: 184,
                height: 58,
                alignment: .leading
            )
            .frame(minHeight: 58, maxHeight: 58)
            .background(InstrumentDesign.ColorRole.cleanup.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(InstrumentDesign.ColorRole.cleanup.opacity(0.34), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.text("查看可安全清理的缓存"))
        .accessibilityIdentifier("storage-map-safe-cleanup")
        .onHover { isSafeCleanupHovering = $0 }
        .visualEffectShadow(
            color: InstrumentDesign.ColorRole.cleanup.opacity(isSafeCleanupHovering ? 0.28 : 0.14),
            radius: isSafeCleanupHovering ? 14 : 9,
            y: 0
        )
        .animation(.easeOut(duration: 0.2), value: isSafeCleanupHovering)
    }

    private var analysisButton: some View {
        Button(action: isAnalysisRunning ? stopAnalysis : startAnalysis) {
            HStack(spacing: 10) {
                ZStack {
                    if isAnalysisRunning {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .bold))
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
                .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text(isAnalysisRunning ? "停止分析" : "重新分析"))
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(L10n.text(isAnalysisRunning ? "中止本次扫描" : "更新空间占用"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .frame(minWidth: 0, idealWidth: 178, maxWidth: 184)
            .frame(
                width: 184,
                height: 58,
                alignment: .leading
            )
            .frame(minHeight: 58, maxHeight: 58)
            .foregroundStyle(isAnalysisRunning ? Color.orange : Color.accentColor)
            .background(
                (isAnalysisRunning ? Color.orange : Color.accentColor)
                    .opacity(isAnalysisHovering ? 0.16 : 0.09),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        (isAnalysisRunning ? Color.orange : Color.accentColor)
                            .opacity(isAnalysisHovering ? 0.45 : 0.25),
                        lineWidth: 1
                    )
            }
            .overlay {
                if isAnalysisRunning {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(colors: [
                                    Color.orange.opacity(0.02),
                                    Color.orange.opacity(0.16),
                                    Color.orange.opacity(0.72),
                                    Color.orange.opacity(0.16),
                                    Color.orange.opacity(0.02)
                                ]),
                                center: .center,
                                angle: .degrees(stopFlowAngle)
                            ),
                            lineWidth: 1.6
                        )
                        .visualEffectShadow(color: Color.orange.opacity(0.16), radius: 3)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help(isAnalysisRunning ? L10n.text("停止分析") : L10n.text("重新分析空间地图"))
        .accessibilityIdentifier("storage-map-reanalyze")
        .accessibilityLabel(L10n.text(isAnalysisRunning ? "停止分析" : "重新分析"))
        .accessibilityHint(L10n.text(isAnalysisRunning ? "中止当前空间扫描" : "重新扫描已识别的应用、工具和数据位置"))
        .disabled(model.phase == .detecting || model.phase == .stopping || model.candidates.isEmpty)
        .onHover { isAnalysisHovering = $0 }
        .visualEffectShadow(
            color: (isAnalysisRunning ? Color.orange : Color.accentColor)
                .opacity(isAnalysisHovering ? 0.22 : 0.08),
            radius: isAnalysisHovering ? 12 : 6,
            y: 0
        )
        .animation(.easeOut(duration: 0.18), value: isAnalysisHovering)
        .animation(.easeOut(duration: 0.18), value: isAnalysisRunning)
        .onAppear {
            startStopFlowIfNeeded()
        }
        .onChange(of: isAnalysisRunning) { _, isRunning in
            if isRunning {
                startStopFlowIfNeeded()
            } else {
                stopFlowAngle = -42
            }
        }
    }

    private func startStopFlowIfNeeded() {
        guard isAnalysisRunning else { return }
        stopFlowAngle = -42
        withAnimation(.linear(duration: 2.8).repeatForever(autoreverses: false)) {
            stopFlowAngle = 318
        }
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
        return L10n.number(model.snapshot?.results.count ?? model.candidates.count)
    }

    private var entryCount: String {
        model.presentationEntryCount.map { L10n.number($0) } ?? "—"
    }

    private var safeCleanupValue: String {
        guard model.snapshot != nil else { return "—" }
        return AgentStorageSizeFormatter.string(safeCleanupBytes)
    }

    private var volumeCount: String {
        let count = model.presentationVolumes.count
        return count > 0 ? L10n.number(count) : "—"
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
        .padding(16)
        .glassSurface(padding: 0)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .animation(.smooth(duration: 0.34), value: volume)
    }

    private var usedPercentage: String {
        guard volume.totalCapacity > 0 else { return L10n.percent(0) }
        return L10n.percent(Double(volume.usedBytes) / Double(volume.totalCapacity))
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
        case .vscode: Color(red: 0.13, green: 0.56, blue: 0.82)
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
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.12),
                                Color.primary.opacity(0.10),
                                Color.black.opacity(0.22)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Capsule()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: proxy.size.width * usedShare)
                if identifiedShare > 0 {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    InstrumentDesign.ColorRole.cpu.opacity(0.96),
                                    InstrumentDesign.ColorRole.read.opacity(0.72)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: max(4, proxy.size.width * identifiedShare - 1.5))
                        .padding(.vertical, 1.5)
                        .help(L10n.text("已识别空间"))
                        .accessibilityLabel(L10n.text("已识别空间"))
                        .accessibilityValue(AgentStorageSizeFormatter.string(identifiedBytes))
                }
                Capsule()
                    .fill(Color.white.opacity(0.42))
                    .frame(width: 1)
                    .offset(x: max(0, proxy.size.width * usedShare - 0.5))
                    .accessibilityHidden(true)
                LinearGradient(
                    colors: [Color.white.opacity(0.22), .clear, Color.black.opacity(0.10)],
                    startPoint: .top,
                    endPoint: .bottomTrailing
                )
                .allowsHitTesting(false)
            }
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.6)
            }
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        }
        .frame(height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("磁盘空间使用构成"))
        .accessibilityValue(L10n.percent(Double(usedShare)))
    }

    private var identifiedSegments: [StorageCapacitySegment] {
        segments.filter { $0.id != "other" && $0.id != "available" }
    }

    private var identifiedShare: CGFloat {
        identifiedSegments.reduce(CGFloat.zero) { partial, segment in
            partial + segment.share
        }
    }

    private var identifiedBytes: UInt64 {
        identifiedSegments.reduce(UInt64.zero) { partial, segment in
            partial.addingClamped(segment.bytes)
        }
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
                Text(L10n.text(item.candidate.descriptor.title))
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
    let refreshError: String?
    let isFullAnalysisRunning: Bool
    let hasFullDiskRepositoryAccess: Bool
    let startAnalysis: () -> Void
    let refreshRepositoryAuthorization: () -> Bool
    let goBack: () -> Void
    let didCleanup: () -> Void
    @State private var selectedResourceIDs: Set<String> = []
    @State private var resourceProjection: StorageResourceTreeIndex?
    @State private var didInitializeCleanupSelection = false
    @State private var didCustomizeCleanupSelection = false
    @State private var pendingSynchronizationIDs = Set<String>()
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
                    Text(L10n.text(item.candidate.descriptor.title)).font(.headline)
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
                        Text(L10n.text("正在同步最新状态"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let refreshError {
                    HStack(spacing: 7) {
                        Label(refreshError, systemImage: "exclamationmark.triangle.fill")
                            .lineLimit(1)
                            .help(refreshError)
                        Button(action: startAnalysis) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .help(L10n.text("重试同步"))
                        .accessibilityLabel(L10n.text("重试同步"))
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
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
                    if let resourceProjection,
                       !resourceProjection.selectedRequests(for: selectedResourceIDs).isEmpty {
                        cleanupSelectionBar(resourceProjection)
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
        .navigationTitle(L10n.text(item.candidate.descriptor.title))
        .task(id: item.resultRevision) { await prepareResourceProjection() }
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
                    pendingSynchronizationIDs.formUnion(succeeded)
                    didCleanup()
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
            func inventoryCounts(in nodes: [StorageResourceNode]) -> (repositories: Int, worktrees: Int) {
                nodes.reduce(into: (repositories: 0, worktrees: 0)) { counts, node in
                    if node.kind == .repository { counts.repositories += 1 }
                    if node.kind == .worktree { counts.worktrees += 1 }
                    let nested = inventoryCounts(in: node.children)
                    counts.repositories += nested.repositories
                    counts.worktrees += nested.worktrees
                }
            }
            let inventory = inventoryCounts(in: result.resourceTree)
            return L10n.format(
                "已识别 %d 个仓库 · %d 个 Worktree",
                inventory.repositories,
                inventory.worktrees
            )
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

            Group {
                if let resourceProjection {
                    StorageResourceTreeView(
                        projection: resourceProjection,
                        categoryDescription: profile.categoryDescription,
                        selectedIDs: $selectedResourceIDs,
                        pendingSynchronizationIDs: pendingSynchronizationIDs,
                        onSelectionInteraction: { didCustomizeCleanupSelection = true }
                    )
                } else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("正在准备资源明细"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 112)
                    .accessibilityElement(children: .combine)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.48))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))

            if let diagnostic = result.inventoryDiagnostic {
                Label(L10n.text(diagnostic), systemImage: "exclamationmark.triangle")
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

    private func rawResourceNodes(_ result: StorageSourceResult) -> [StorageResourceNode] {
        let nodes: [StorageResourceNode]
        if result.resourceTree.isEmpty {
            nodes = StorageComponentPresentation.aggregate(result.components).map { component in
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
        } else {
            nodes = result.resourceTree
        }
        return nodes
    }

    @MainActor
    private func prepareResourceProjection() async {
        guard let result = item.result else {
            resourceProjection = nil
            return
        }
        await Task.yield()
        let nodes = rawResourceNodes(result)
        let projection = await Task.detached(priority: .userInitiated) {
            StorageResourceTreeIndex(nodes: nodes)
        }.value
        guard !Task.isCancelled else { return }
        resourceProjection = projection
        pendingSynchronizationIDs.removeAll()

        if didInitializeCleanupSelection {
            selectedResourceIDs.formIntersection(Set(projection.requestsByID.keys))
        } else if !didCustomizeCleanupSelection,
                  !projection.safeRequestIDs.isEmpty || result.isComplete {
            selectedResourceIDs = projection.safeRequestIDs
            didInitializeCleanupSelection = true
        }
    }

    private func cleanupSelectionBar(_ projection: StorageResourceTreeIndex) -> some View {
        let actionableRequestIDs = Set(projection.requestsByID.keys)
            .subtracting(pendingSynchronizationIDs)
        let requests = projection.selectedRequests(
            for: selectedResourceIDs.subtracting(pendingSynchronizationIDs)
        )
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
            Button(L10n.text("清除选择")) {
                didCustomizeCleanupSelection = true
                selectedResourceIDs.removeAll()
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
            Button {
                cleanupReview = StorageCleanupReviewContext(
                    sourceTitle: L10n.text(item.candidate.descriptor.title),
                    sourceID: item.id,
                    requests: requests,
                    remainingRequestCount: actionableRequestIDs.subtracting(requests.map(\.id)).count
                )
            } label: {
                Label(L10n.text("检查并清理"), systemImage: "trash")
            }
            .buttonStyle(AppActionButtonStyle(kind: .primary))
            .disabled(requests.isEmpty)
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
