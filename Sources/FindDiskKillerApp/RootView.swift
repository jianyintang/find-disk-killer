import FindDiskKillerCore
import SwiftUI

enum AppSection: String, CaseIterable, Hashable, Identifiable, Sendable {
    case overview = "现在"
    case processes = "应用"
    case agentStorage = "空间地图"
    case disks = "磁盘"
    case reports = "历史分析"

    var id: String { rawValue }
    var title: String { L10n.text(rawValue) }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .disks: "internaldrive"
        case .processes: "square.stack.3d.up"
        case .agentStorage: "square.grid.3x3.square"
        case .reports: "chart.xyaxis.line"
        }
    }

    var navigationPlaceholderKind: SectionNavigationPlaceholderKind? {
        switch self {
        case .processes: .processes
        case .agentStorage: nil
        case .reports: .history
        case .overview: .overview
        case .disks: .resources
        }
    }

    var showsMonitoringToolbar: Bool {
        self != .agentStorage
    }
}

enum SectionNavigationPlaceholderKind: Equatable, Sendable {
    case overview
    case processes
    case history
    case resources
}

private enum SidebarLayoutContract {
    static let brandHeight: CGFloat = 84
    static let statusHeight: CGFloat = 68
}

struct RootView: View {
    let store: MonitorStore
    let processDetailWindows: ProcessDetailWindowCoordinator
    let history: HistoryModel
    let navigation: AppNavigationCoordinator
    let updates: UpdateCoordinator
    let agentStorage: AgentStorageModel
    let storageMap: StorageMapModel
    let claudeNodeRuntime: ClaudeNodeRuntimeStatusModel
    @State private var requestedSection: AppSection
    @State private var loadedSection: AppSection
    @State private var sectionSnapshots: [AppSection: SectionPreviewSnapshot] = [:]
    @State private var processSearchText = ""
    @State private var isWindowLiveResizing = false
    @State private var presentedAuxiliaryPage: AuxiliaryPage?
    @State private var auxiliarySwitchTask: Task<Void, Never>?
    @State private var isReturningFromAuxiliary = false
    @Environment(\.visualEffectLevel) private var visualEffectLevel

    init(
        store: MonitorStore,
        processDetailWindows: ProcessDetailWindowCoordinator,
        history: HistoryModel,
        agentStorage: AgentStorageModel,
        storageMap: StorageMapModel,
        claudeNodeRuntime: ClaudeNodeRuntimeStatusModel,
        navigation: AppNavigationCoordinator,
        updates: UpdateCoordinator
    ) {
        self.store = store
        self.processDetailWindows = processDetailWindows
        self.history = history
        self.agentStorage = agentStorage
        self.storageMap = storageMap
        self.claudeNodeRuntime = claudeNodeRuntime
        self.navigation = navigation
        self.updates = updates
        _requestedSection = State(initialValue: navigation.lastMonitoringDestination)
        _loadedSection = State(initialValue: navigation.lastMonitoringDestination)
    }

    var body: some View {
        NavigationSplitView {
            ZStack {
                InstrumentDesign.Palette.sidebarTint
                if visualEffectLevel.usesSurfaceMaterial {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(0.72)
                }

                VStack(spacing: 0) {
                    sidebarBrand
                        .frame(height: SidebarLayoutContract.brandHeight)
                    List {
                        Section {
                            ForEach(AppSection.allCases) { section in
                                sidebarRow(
                                    title: section.title,
                                    symbol: section.symbol,
                                    destination: .monitoring(section)
                                )
                            }
                        }

                        Section {
                            sidebarRow(
                                title: L10n.text("设置"),
                                symbol: "gearshape",
                                destination: .settings
                            )
                            sidebarRow(
                                title: L10n.text("关于"),
                                symbol: "info.circle",
                                destination: .about
                            )
                        }
                    }
                    .navigationTitle("")
                    .listStyle(.sidebar)
                    .tint(Color.secondary.opacity(0.74))
                    .accentColor(Color.secondary.opacity(0.74))
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    sidebarStatus
                        .frame(height: SidebarLayoutContract.statusHeight)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationSplitViewColumnWidth(min: 220, ideal: 232, max: 260)
        } detail: {
            ZStack {
                InstrumentCanvas()
                presentedDetail
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("")
                .toolbar {
                    if isShowingAuxiliaryPage || requestedSection.showsMonitoringToolbar {
                        StatusToolbar(store: store)
                    } else {
                        // Keep the unified compact toolbar's primary-action slot stable
                        // while Storage Map owns its actions inside the page.
                        ToolbarItem(placement: .primaryAction) {
                            Color.clear
                                .frame(width: 28, height: 24)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .task(id: requestedSection) {
                    await loadRequestedSection()
                }
        }
        .tint(InstrumentDesign.ColorRole.cpu)
        .environment(\.isWindowLiveResizing, isWindowLiveResizing)
        .onChange(of: navigation.destination) { _, newValue in
            switch newValue {
            case .monitoring:
                // 从设置/关于页返回时，先显示轻量骨架（高亮当帧只做轻量重绘），
                // 50ms 后再重建监控页视图树，避免其构建（含 TextField 等）拖累高亮帧。
                let wasAuxiliary = presentedAuxiliaryPage != nil
                auxiliarySwitchTask?.cancel()
                auxiliarySwitchTask = nil
                presentedAuxiliaryPage = nil
                if wasAuxiliary {
                    isReturningFromAuxiliary = true
                    auxiliarySwitchTask = Task { @MainActor in
                        do {
                            try await Task.sleep(for: .milliseconds(50))
                        } catch {
                            return
                        }
                        guard !Task.isCancelled else { return }
                        isReturningFromAuxiliary = false
                    }
                }
            case .settings:
                scheduleAuxiliaryPage(.settings)
            case .about:
                scheduleAuxiliaryPage(.about)
            }
        }
        .transaction { transaction in
            if isWindowLiveResizing || visualEffectLevel.disablesMotion {
                transaction.disablesAnimations = true
            }
        }
        .background {
            ZStack {
                InstrumentWindowConfigurator(visualEffectLevel: visualEffectLevel)
                WindowLiveResizeObserver { isResizing in
                    updateWindowLiveResizeState(isResizing)
                }
            }
        }
    }

    private func scheduleAuxiliaryPage(_ page: AuxiliaryPage) {
        auxiliarySwitchTask?.cancel()
        auxiliarySwitchTask = Task { @MainActor in
            // 让选中高亮在当前帧完成渲染后再构建设置/关于页，
            // 避免表单（含 TextField）的初始化拖累点击反馈。
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            presentedAuxiliaryPage = page
        }
    }

    private func updateWindowLiveResizeState(_ isResizing: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isWindowLiveResizing = isResizing
        }
    }

    private var sidebarBrand: some View {
        HStack {
            Text("FindDiskKiller")
                .font(.system(size: 20, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 48)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sidebarStatus: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(store.isCollecting
                    ? InstrumentDesign.ColorRole.healthy.opacity(0.82)
                    : Color.secondary.opacity(0.48))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("现在"))
                    .font(.system(size: 13, weight: .medium))
                Text(L10n.text("实时监控"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background {
            if visualEffectLevel.usesSurfaceMaterial {
                Color.clear.background(.ultraThinMaterial)
            } else {
                InstrumentDesign.Palette.canvasRaised
            }
        }
        .overlay(alignment: .top) {
            Divider().opacity(0.45)
        }
    }

    private func sidebarRow(
        title: String,
        symbol: String,
        destination: SidebarDestination
    ) -> some View {
        Button {
            selectSidebarDestination(destination)
        } label: {
            Label(title, systemImage: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 14, weight: .regular))
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .padding(.horizontal, 10)
                .background(
                    navigation.destination == destination
                        ? Color.primary.opacity(0.11)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: InstrumentDesign.Radius.control)
                )
                .overlay {
                    if navigation.destination == destination {
                        RoundedRectangle(cornerRadius: InstrumentDesign.Radius.control)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
    }

    private func selectSidebarDestination(_ destination: SidebarDestination) {
        // 选中态与目标页同步提交：骨架屏轻量，高亮与骨架在同一帧完成渲染。
        // 设置/关于页的真实内容由 onChange(of: navigation.destination) 分帧提交，
        // 避免其较重的表单构建（含 TextField 等）拖累高亮帧。
        navigation.select(destination)
        guard case .monitoring(let section) = destination,
              section != requestedSection else { return }
        requestedSection = section
    }

    @ViewBuilder
    private var presentedDetail: some View {
        switch navigation.destination {
        case .monitoring:
            detail
        case .settings:
            if presentedAuxiliaryPage == .settings {
                SettingsPage(
                    store: store,
                    history: history,
                    navigation: navigation,
                    updates: updates,
                    agentStorage: agentStorage,
                    nodeRuntime: claudeNodeRuntime
                )
            } else {
                AuxiliaryPagePlaceholder(title: L10n.text("设置"))
            }
        case .about:
            if presentedAuxiliaryPage == .about {
                AboutPage(updates: updates)
            } else {
                AuxiliaryPagePlaceholder(title: L10n.text("关于"))
            }
        }
    }

    private var isShowingAuxiliaryPage: Bool {
        switch navigation.destination {
        case .settings, .about: true
        case .monitoring: false
        }
    }

    @ViewBuilder
    private var detail: some View {
        if requestedSection.navigationPlaceholderKind == nil {
            sectionDetail(requestedSection)
        } else if requestedSection == loadedSection && !isReturningFromAuxiliary {
            loadedDetail
        } else {
            SectionNavigationPlaceholder(
                section: requestedSection,
                snapshot: sectionSnapshots[requestedSection],
                selectedRange: Bindable(store).selectedRange,
                processSearchText: $processSearchText,
                liveVolumeCount: store.volumes.filter(\.isLocal).count
            )
        }
    }

    @ViewBuilder
    private var loadedDetail: some View {
        sectionDetail(loadedSection)
    }

    @ViewBuilder
    private func sectionDetail(_ section: AppSection) -> some View {
        switch section {
        case .overview:
            OverviewView(store: store, processDetailWindows: processDetailWindows)
        case .disks:
            DisksView(store: store)
        case .processes:
            ProcessesView(
                store: store,
                searchText: $processSearchText,
                processDetailWindows: processDetailWindows
            )
        case .agentStorage:
            StorageMapView(
                model: storageMap,
                agentStorage: agentStorage,
                nodeRuntime: claudeNodeRuntime
            )
        case .reports:
            HistoryReportView(history: history) {
                navigation.showSettings(.dataAndPrivacy)
            }
        }
    }

    private func loadRequestedSection() async {
        let target = requestedSection
        guard target != loadedSection else { return }
        let departing = loadedSection

        // Storage Map has no navigation skeleton. Commit it directly so the root
        // does not keep a second, invisible loading transition alive after the
        // page is already visible.
        if target.navigationPlaceholderKind == nil {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                loadedSection = target
            }
            return
        }

        // 立即在后台并行捕获离开页面的快照，与合并延迟重叠，
        // 保证快速来回切换时占位页能尽快显示上一帧的真实数据。
        let departingSnapshotTask = Task { @MainActor in
            await SectionPreviewSnapshot.capture(section: departing, store: store)
        }

        do {
            // Coalesce rapid navigation so only the page the user settles on builds its
            // charts and scrolling hierarchy. The cached placeholder is already visible.
            try await Task.sleep(for: .milliseconds(120))
        } catch {
            return
        }
        guard !Task.isCancelled, requestedSection == target else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            loadedSection = target
        }

        // 页面切换不被快照构建阻塞；快照完成后再更新缓存，供下次访问使用。
        let departingSnapshot = await departingSnapshotTask.value
        guard !Task.isCancelled, requestedSection == target else { return }
        sectionSnapshots[departing] = departingSnapshot

        do {
            try await Task.sleep(for: .milliseconds(120))
        } catch {
            return
        }
        guard !Task.isCancelled, requestedSection == target else { return }
        let targetSnapshot = await SectionPreviewSnapshot.capture(
            section: target,
            store: store
        )
        guard !Task.isCancelled, requestedSection == target else { return }
        sectionSnapshots[target] = targetSnapshot
    }
}

private enum AuxiliaryPage: Equatable {
    case settings
    case about
}

private struct AuxiliaryPagePlaceholder: View {
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                    .frame(width: 56, height: 17)
                Spacer(minLength: 12)
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 260, height: 30)
            }
            .padding(.horizontal, InstrumentPageHeaderLayout.horizontalPadding)
            .padding(.top, InstrumentPageHeaderLayout.topPadding)
            .padding(.bottom, InstrumentPageHeaderLayout.bottomPadding)
            .frame(minHeight: InstrumentPageHeaderLayout.minimumHeight)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(spacing: 0) {
                            ForEach(0..<3, id: \.self) { _ in
                                HStack(spacing: 12) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(.quaternary)
                                        .frame(width: 110, height: 11)
                                    Spacer(minLength: 12)
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(.quaternary.opacity(0.7))
                                        .frame(width: 90, height: 22)
                                }
                                .frame(height: 44)
                                Divider()
                            }
                        }
                        .glassSurface(padding: 14)
                    }
                }
                .padding(InstrumentDesign.Spacing.page)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(InstrumentCanvas())
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.format("正在准备%@…", title))
    }
}

private struct InstrumentWindowConfigurator: NSViewRepresentable {
    let visualEffectLevel: VisualEffectLevel

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.configureWhenAttached(to: view, visualEffectLevel: visualEffectLevel)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.configure(window: nsView.window, visualEffectLevel: visualEffectLevel)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        private weak var configuredWindow: NSWindow?
        private var configuredVisualEffectLevel: VisualEffectLevel?
        private var isWaitingForAttachment = false

        func configureWhenAttached(to view: NSView, visualEffectLevel: VisualEffectLevel) {
            configure(window: view.window, visualEffectLevel: visualEffectLevel)
            guard configuredWindow == nil, !isWaitingForAttachment else { return }
            isWaitingForAttachment = true
            DispatchQueue.main.async { [weak self, weak view, visualEffectLevel] in
                guard let self else { return }
                self.isWaitingForAttachment = false
                self.configure(window: view?.window, visualEffectLevel: visualEffectLevel)
            }
        }

        func configure(window: NSWindow?, visualEffectLevel: VisualEffectLevel) {
            guard let window else { return }
            guard configuredWindow !== window
                    || configuredVisualEffectLevel != visualEffectLevel else { return }
            configuredWindow = window
            configuredVisualEffectLevel = visualEffectLevel
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = !visualEffectLevel.usesCanvasMaterial
            window.backgroundColor = visualEffectLevel.usesCanvasMaterial
                ? .clear
                : .windowBackgroundColor
            window.styleMask.insert(.fullSizeContentView)
            window.toolbarStyle = .unifiedCompact
            window.contentView?.needsDisplay = true
        }
    }
}

private struct SectionPreviewSnapshot: Sendable {
    let capturedAt: Date
    let processes: [ProcessPreviewRow]
    let volumes: [VolumePreviewRow]

    @MainActor
    static func capture(section: AppSection, store: MonitorStore) async -> Self {
        let input = SectionPreviewInput(
            section: section,
            capturedAt: Date(),
            processes: store.processes,
            volumes: store.volumes,
            disks: store.disks
        )
        return await Task.detached(priority: .utility) {
            build(input)
        }.value
    }

    nonisolated private static func build(_ input: SectionPreviewInput) -> Self {
        let processes: [ProcessPreviewRow]
        if input.section == .processes || input.section == .overview {
            let limit = input.section == .overview ? 12 : 6
            processes = input.processes
                .sorted { $0.currentCPUPercent > $1.currentCPUPercent }
                .prefix(limit)
                .map(ProcessPreviewRow.init)
        } else {
            processes = []
        }

        let volumes: [VolumePreviewRow]
        if input.section == .disks || input.section == .overview {
            volumes = input.volumes.filter(\.isLocal).prefix(5).map { volume in
                let disks = input.disks.filter {
                    $0.isPhysical && volume.physicalDiskBSDNames.contains($0.bsdName)
                }
                return VolumePreviewRow(
                    id: volume.id,
                    name: volume.name,
                    readRate: disks.reduce(0) { $0 + $1.readBytesPerSecond },
                    writeRate: disks.reduce(0) { $0 + $1.writeBytesPerSecond }
                )
            }
        } else {
            volumes = []
        }

        return Self(
            capturedAt: input.capturedAt,
            processes: processes,
            volumes: volumes
        )
    }
}

private struct SectionPreviewInput: Sendable {
    let section: AppSection
    let capturedAt: Date
    let processes: [ProcessActivity]
    let volumes: [VolumeInfo]
    let disks: [DiskActivity]
}

private struct ProcessPreviewRow: Identifiable, Sendable {
    let id: String
    let name: String
    let subtitle: String
    let cpu: String
    let totalWrite: String
    let currentWrite: String
    let peakWrite: String
    let download: String
    let upload: String

    init(_ process: ProcessActivity) {
        id = process.id
        name = process.localizedDisplayName
        subtitle = process.memberCount > 1
            ? L10n.format("%d 个进程 · 全盘合计", process.memberCount)
            : L10n.text("全盘 I/O 合计")
        cpu = process.currentUnavailableMetrics.contains(.cpu)
            ? L10n.text("不可用") : PercentFormatter.cpu(process.currentCPUPercent)
        totalWrite = process.intervalUnavailableMetrics.contains(.write)
            ? L10n.text("不可用") : ByteRateFormatter.bytes(process.totalWriteBytes)
        currentWrite = process.currentUnavailableMetrics.contains(.write)
            ? L10n.text("不可用")
            : ByteRateFormatter.rate(process.currentWriteBytesPerSecond)
        peakWrite = process.intervalUnavailableMetrics.contains(.write)
            ? L10n.text("不可用")
            : ByteRateFormatter.rate(process.peakWriteBytesPerSecond)
        download = process.isNetworkAvailable
            ? ByteRateFormatter.rate(process.averageNetworkReceiveBytesPerSecond)
            : L10n.text("不可用")
        upload = process.isNetworkAvailable
            ? ByteRateFormatter.rate(process.averageNetworkSendBytesPerSecond)
            : L10n.text("不可用")
    }

    static func placeholder(_ index: Int) -> Self {
        Self(
            id: "placeholder-\(index)",
            name: L10n.text("应用"),
            subtitle: L10n.text("全盘 I/O 合计"),
            cpu: "00.0%",
            totalWrite: "000 MB",
            currentWrite: "0.00 MB/s",
            peakWrite: "0.00 MB/s",
            download: "0.00 MB/s",
            upload: "0.00 MB/s"
        )
    }

    private init(
        id: String,
        name: String,
        subtitle: String,
        cpu: String,
        totalWrite: String,
        currentWrite: String,
        peakWrite: String,
        download: String,
        upload: String
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.cpu = cpu
        self.totalWrite = totalWrite
        self.currentWrite = currentWrite
        self.peakWrite = peakWrite
        self.download = download
        self.upload = upload
    }
}

private struct VolumePreviewRow: Identifiable, Sendable {
    let id: String
    let name: String
    let readRate: Double
    let writeRate: Double
}

private struct SectionNavigationPlaceholder: View {
    let section: AppSection
    let snapshot: SectionPreviewSnapshot?
    @Binding var selectedRange: SampleRange
    @Binding var processSearchText: String
    let liveVolumeCount: Int
    @State private var processTableWidth: CGFloat = 0

    var body: some View {
        Group {
            switch section.navigationPlaceholderKind {
            case .some(.overview):
                overviewPlaceholder
            case .some(.processes):
                processPlaceholder
            case .some(.history):
                HistoryReportNavigationPlaceholder()
            case .some(.resources):
                resourcePlaceholder
            case nil:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var statusLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: snapshot == nil ? "clock" : "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            if let snapshot {
                Text(L10n.format(
                    "正在刷新 · 上次结果 %@",
                    L10n.date(snapshot.capturedAt, date: .omitted, time: .standard)
                ))
            } else {
                Text(section == .processes
                    ? L10n.text("正在读取应用活动…")
                    : L10n.format("正在准备%@…", section.title))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var overviewPlaceholder: some View {
        ZStack {
            InstrumentCanvas()
            ScrollView {
                LazyVStack(
                    alignment: .leading,
                    spacing: OverviewLayoutContract.contentSpacing
                ) {
                    overviewHeaderPlaceholder
                    overviewMetricGridPlaceholder
                    overviewDiskActivityPlaceholder
                    overviewApplicationSectionPlaceholder
                }
                .padding(.horizontal, InstrumentDesign.Spacing.page)
                .padding(.top, OverviewLayoutContract.pageTopPadding)
                .padding(.bottom, OverviewLayoutContract.pageBottomPadding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sectionLoadingAccessibilityLabel)
    }

    private var overviewHeaderPlaceholder: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 18) {
                overviewDiagnosticPlaceholder
                Spacer(minLength: 12)
                overviewRangePlaceholder
                overviewLivePlaceholder
            }

            VStack(alignment: .leading, spacing: 10) {
                overviewDiagnosticPlaceholder
                HStack(spacing: 12) {
                    overviewRangePlaceholder
                    Spacer(minLength: 4)
                    overviewLivePlaceholder
                }
            }
        }
        .frame(minHeight: 62)
    }

    private var overviewDiagnosticPlaceholder: some View {
        HStack(alignment: .center, spacing: 26) {
            Text(L10n.text("诊断"))
                .font(.system(size: 26, weight: .semibold))
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot == nil ? L10n.text("正在建立采样") : L10n.text("应用资源行为正常"))
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                statusLabel
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(width: InstrumentDesign.Layout.diagnosticIdentityWidth, alignment: .leading)
    }

    private var overviewRangePlaceholder: some View {
        GlassSegmentedControl("时间范围", selection: Binding.constant(SampleRange.minute)) {
            ForEach(SampleRange.allCases) { range in
                Text(range.localizedTitle).tag(range)
            }
        }
        .frame(width: 224)
    }

    private var overviewLivePlaceholder: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Circle()
                    .fill(InstrumentDesign.ColorRole.healthy.opacity(0.9))
                    .frame(width: 7, height: 7)
                Text(L10n.text("现在"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Button {} label: {
                Image(systemName: "pause.fill")
            }
            .buttonStyle(AppIconButtonStyle(size: 32))
        }
    }

    private var overviewMetricGridPlaceholder: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(
                    .flexible(minimum: 0),
                    spacing: OverviewLayoutContract.metricSpacing
                ),
                count: OverviewLayoutContract.metricColumnCount
            ),
            spacing: OverviewLayoutContract.metricSpacing
        ) {
            ForEach(0..<OverviewLayoutContract.metricTileCount, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.quaternary)
                            .frame(width: 96, height: 10)
                        Spacer(minLength: 8)
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.quaternary)
                            .frame(width: 28, height: 24)
                    }
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .frame(width: 76, height: 20)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary.opacity(0.55))
                        .frame(height: 48)
                }
                .frame(maxWidth: .infinity, minHeight: 158, alignment: .topLeading)
                .glassSurface(padding: 16)
            }
        }
    }

    private var overviewDiskActivityPlaceholder: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading("磁盘活动", subtitle: "最近 5 秒的设备读写，按挂载卷名称展示") {
                GlassSegmentedControl("资源", selection: Binding.constant("disk")) {
                    Text(L10n.text("磁盘 I/O")).tag("disk")
                    Text("CPU").tag("cpu")
                    Text(L10n.text("网络")).tag("network")
                    Text(L10n.text("内存")).tag("memory")
                }
                .frame(width: OverviewLayoutContract.resourceControlWidth)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    overviewVolumeColumnPlaceholder
                        .frame(minWidth: 270, idealWidth: 310, maxWidth: 340)
                    Divider()
                    overviewChartPlaceholder(height: overviewSkeletonDiskLayout.contentHeight)
                        .frame(minWidth: 430, maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 14) {
                    overviewVolumeColumnPlaceholder
                    Divider()
                    overviewChartPlaceholder(height: overviewSkeletonDiskLayout.contentHeight)
                }
            }
        }
        .overviewPanel()
    }

    private var overviewVolumeColumnPlaceholder: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                DataValue(value: "0.00", unit: "MB/s", size: 44)
                    .redacted(reason: .placeholder)
                Text(L10n.text("当前写入"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(height: OverviewDiskLayout.leadValueHeight, alignment: .topLeading)

            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(previewVolumes) { volume in
                        overviewVolumeRow(volume)
                            .frame(height: overviewSkeletonDiskLayout.rowHeight)
                            .redacted(reason: snapshot == nil ? .placeholder : [])
                    }
                }
            }
            .scrollDisabled(true)
            .frame(height: overviewSkeletonDiskLayout.volumeViewportHeight, alignment: .top)

            overviewDiskSummaryPlaceholder
                .frame(height: OverviewDiskLayout.summaryHeight, alignment: .top)
        }
        .frame(height: overviewSkeletonDiskLayout.contentHeight, alignment: .top)
    }

    private func overviewVolumeRow(_ volume: VolumePreviewRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "internaldrive")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 1) {
                Text(volume.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(L10n.text("设备实时吞吐"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                Text(ByteRateFormatter.rate(volume.readRate))
                    .foregroundStyle(InstrumentDesign.ColorRole.diskRead)
                Text(ByteRateFormatter.rate(volume.writeRate))
                    .foregroundStyle(InstrumentDesign.ColorRole.diskWrite)
            }
            .font(.caption.monospaced().weight(.medium))
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var overviewDiskSummaryPlaceholder: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            Label(L10n.text("物理设备总吞吐"), systemImage: "internaldrive")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                skeletonSummaryValue("读取", color: InstrumentDesign.ColorRole.diskRead)
                skeletonSummaryValue("写入", color: InstrumentDesign.ColorRole.diskWrite)
                skeletonSummaryValue("写入峰值", color: .secondary)
            }
            HStack(spacing: 12) {
                Text(L10n.text("读取"))
                Text(L10n.text("写入"))
                Spacer(minLength: 8)
                EvidenceLabel(text: "虚拟磁盘不计入总量", symbol: "checkmark.shield")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    private func skeletonSummaryValue(_ title: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.text(title))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("0.00 MB/s")
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(color)
                .redacted(reason: .placeholder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func overviewChartPlaceholder(height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { _ in
                    Divider()
                    Spacer()
                }
            }
            HStack(spacing: 14) {
                Label(L10n.text("读取"), systemImage: "circle.fill")
                Label(L10n.text("写入"), systemImage: "circle.fill")
            }
            .font(.caption)
            .padding(.leading, 64)
            .padding(.top, 4)
        }
        .frame(height: height)
    }

    private var overviewApplicationSectionPlaceholder: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("正在活动的应用"))
                        .font(.headline)
                    Text(L10n.text("应用与系统层的磁盘、CPU 与网络活动汇总在同一处"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(L10n.text("点击表头排序 · 显示前 12 个"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)

            overviewApplicationTable
        }
        .overviewPanel(horizontalPadding: 16, verticalPadding: 14)
    }

    private var overviewSkeletonDiskLayout: OverviewDiskLayout {
        OverviewDiskLayout(volumeCount: previewVolumes.count)
    }

    private var overviewApplicationTable: some View {
        ScrollView(.horizontal) {
            VStack(spacing: 0) {
                previewTableHeader
                Divider()
                ForEach(previewProcesses) { process in
                    previewProcessRow(process)
                    Divider().padding(.leading, 8)
                }
            }
            .frame(width: previewTableWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scrollIndicators(.automatic)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ProcessPlaceholderWidthPreferenceKey.self,
                    value: geometry.size.width
                )
            }
        }
        .onPreferenceChange(ProcessPlaceholderWidthPreferenceKey.self) { width in
            guard width.isFinite, width > 0, abs(width - processTableWidth) > 0.5 else { return }
            processTableWidth = width
        }
    }

    private var processPlaceholder: some View {
        VStack(spacing: 0) {
            processHeaderPlaceholder

            Group {
                ScrollView([.horizontal, .vertical]) {
                    VStack(spacing: 0) {
                        previewTableHeader
                        Divider()
                        ForEach(previewProcesses) { process in
                            previewProcessRow(process)
                            Divider().padding(.leading, 14)
                        }
                    }
                    .frame(width: previewTableWidth, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .scrollIndicators(.automatic)
                .defaultScrollAnchor(.topLeading)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ProcessPlaceholderWidthPreferenceKey.self,
                            value: geometry.size.width
                        )
                    }
                }
                .onPreferenceChange(ProcessPlaceholderWidthPreferenceKey.self) { width in
                    guard width.isFinite, width > 0, abs(width - processTableWidth) > 0.5 else { return }
                    processTableWidth = width
                }
            }
            .glassSurface(padding: 0)
            .padding(.top, InstrumentDesign.Spacing.related)
            .padding(.horizontal, InstrumentDesign.Spacing.page)
            .padding(.bottom, InstrumentDesign.Spacing.page)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(processLoadingAccessibilityLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var processHeaderPlaceholder: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                    .frame(width: 56, height: 17)
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary.opacity(0.7))
                    .frame(width: 130, height: 9)
            }
            Spacer(minLength: 12)
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 260, height: 30)
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary.opacity(0.7))
                .frame(width: 240, height: 30)
        }
        .padding(.horizontal, InstrumentPageHeaderLayout.horizontalPadding)
        .padding(.top, InstrumentPageHeaderLayout.topPadding)
        .padding(.bottom, InstrumentPageHeaderLayout.bottomPadding)
        .frame(minHeight: InstrumentPageHeaderLayout.minimumHeight)
        .accessibilityHidden(true)
    }

    private var processLoadingAccessibilityLabel: String {
        if let snapshot {
            return L10n.format(
                "正在刷新 · 上次结果 %@",
                L10n.date(snapshot.capturedAt, date: .omitted, time: .standard)
            )
        }
        return L10n.text("正在读取应用活动…")
    }

    private var resourcePlaceholder: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 18) {
                    ForEach(0..<4, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 7) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.quaternary)
                                .frame(width: 76, height: 10)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.quaternary)
                                .frame(width: 112, height: 22)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary.opacity(0.55))
                    .frame(height: 220)

                VStack(spacing: 0) {
                    ForEach(previewVolumes) { volume in
                        HStack(spacing: 12) {
                            Image(systemName: "internaldrive")
                                .foregroundStyle(.secondary)
                                .frame(width: 28)
                            Text(volume.name)
                                .lineLimit(1)
                            Spacer()
                            Text(ByteRateFormatter.rate(volume.readRate))
                                .foregroundStyle(.teal)
                            Text(ByteRateFormatter.rate(volume.writeRate))
                                .foregroundStyle(.orange)
                                .frame(width: 110, alignment: .trailing)
                        }
                        .frame(height: 50)
                        .redacted(reason: snapshot == nil ? .placeholder : [])
                        Divider()
                    }
                }
            }
            .padding(22)
        }
        .overlay(alignment: .topTrailing) {
            statusLabel.padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var previewProcesses: [ProcessPreviewRow] {
        guard let processes = snapshot?.processes, !processes.isEmpty else {
            let count = section == .overview
                ? OverviewLayoutContract.applicationRowLimit
                : ProcessTableLayoutContract.loadingRowCount
            return (0..<count).map(ProcessPreviewRow.placeholder)
        }
        return processes
    }

    private var previewVolumes: [VolumePreviewRow] {
        guard let volumes = snapshot?.volumes, !volumes.isEmpty else {
            return (0..<liveVolumeCount).map {
                VolumePreviewRow(
                    id: "placeholder-\($0)",
                    name: L10n.text("磁盘"),
                    readRate: 0,
                    writeRate: 0
                )
            }
        }
        return volumes
    }

    private var sectionLoadingAccessibilityLabel: String {
        guard let snapshot else {
            return L10n.format("正在准备%@…", section.title)
        }
        return L10n.format(
            "正在刷新 · 上次结果 %@",
            L10n.date(snapshot.capturedAt, date: .omitted, time: .standard)
        )
    }

    private var previewTableHeader: some View {
        let widths = previewColumnWidths
        return HStack(spacing: 0) {
            previewHeader("应用", width: widths[.application], alignment: .leading)
            previewColumnGap
            previewHeader("CPU · 5 秒", width: widths[.cpu])
            previewColumnGap
            previewHeader("写入总量", width: widths[.writeTotal])
            previewColumnGap
            previewHeader("当前写入", width: widths[.writeCurrent])
            previewColumnGap
            previewHeader("写入峰值", width: widths[.writePeak])
            previewColumnGap
            previewHeader("下载平均", width: widths[.networkDownload])
            previewColumnGap
            previewHeader("上传平均", width: widths[.networkUpload])
            previewColumnGap
        }
        .padding(.horizontal, 14)
        .frame(height: ProcessTableLayoutContract.headerHeight)
    }

    private func previewHeader(
        _ title: String,
        width: CGFloat,
        alignment: Alignment = .trailing
    ) -> some View {
        Text(L10n.text(title))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: alignment)
    }

    private func previewProcessRow(_ process: ProcessPreviewRow) -> some View {
        let widths = previewColumnWidths
        return HStack(spacing: 0) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(process.name).lineLimit(1)
                    Text(process.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: widths[.application], alignment: .leading)
            previewColumnGap
            previewValue(process.cpu, width: widths[.cpu])
            previewColumnGap
            previewValue(process.totalWrite, width: widths[.writeTotal])
            previewColumnGap
            previewValue(process.currentWrite, width: widths[.writeCurrent])
            previewColumnGap
            previewValue(process.peakWrite, width: widths[.writePeak])
            previewColumnGap
            previewValue(process.download, width: widths[.networkDownload])
            previewColumnGap
            previewValue(process.upload, width: widths[.networkUpload])
            previewColumnGap
        }
        .padding(.horizontal, 14)
        .frame(height: ProcessTableLayoutContract.rowHeight)
        .redacted(reason: snapshot == nil ? .placeholder : [])
    }

    private func previewValue(_ value: String, width: CGFloat) -> some View {
        Text(value)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .trailing)
    }

    private var previewColumnWidths: ProcessColumnWidths {
        ProcessColumnWidths.load().adapted(to: processTableWidth)
    }

    private var previewTableWidth: CGFloat {
        previewColumnWidths.tableWidth
    }

    private var previewColumnGap: some View {
        Color.clear.frame(width: ProcessColumn.resizeHandleWidth)
    }
}

private struct ProcessPlaceholderWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct StatusToolbar: ToolbarContent {
    let store: MonitorStore

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                store.isCollecting ? store.stop() : store.start()
            } label: {
                Image(systemName: store.isCollecting ? "stop.fill" : "play.fill")
            }
            .help(L10n.text(store.isCollecting ? "停止采集" : "开始采集"))
        }
    }

}
