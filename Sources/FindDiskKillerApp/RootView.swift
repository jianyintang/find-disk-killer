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
            List(selection: sidebarSelection) {
                Section {
                    ForEach(AppSection.allCases) { section in
                        Label(section.title, systemImage: section.symbol)
                            .tag(SidebarDestination.monitoring(section))
                    }
                }

                Section {
                    Label(L10n.text("设置"), systemImage: "gearshape")
                        .tag(SidebarDestination.settings)
                    Label(L10n.text("关于"), systemImage: "info.circle")
                        .tag(SidebarDestination.about)
                }
            }
            .navigationTitle("FindDiskKiller")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 240)
        } detail: {
            ZStack {
                detail
                    .opacity(isShowingAuxiliaryPage ? 0 : 1)
                    .allowsHitTesting(!isShowingAuxiliaryPage)
                    .accessibilityHidden(isShowingAuxiliaryPage)

                auxiliaryDetail
            }
                .navigationTitle(detailTitle)
                .toolbar {
                    if isShowingAuxiliaryPage || requestedSection.showsMonitoringToolbar {
                        StatusToolbar(store: store)
                    }
                }
                .task(id: requestedSection) {
                    await loadRequestedSection()
                }
        }
    }

    private var detailTitle: String {
        switch navigation.destination {
        case .monitoring(let section): section.title
        case .settings: L10n.text("设置")
        case .about: L10n.text("关于")
        }
    }

    @ViewBuilder
    private var auxiliaryDetail: some View {
        switch navigation.destination {
        case .settings:
            SettingsPage(
                store: store,
                history: history,
                navigation: navigation,
                updates: updates,
                agentStorage: agentStorage,
                nodeRuntime: claudeNodeRuntime
            )
        case .about:
            AboutPage(updates: updates)
        case .monitoring:
            EmptyView()
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
        } else if requestedSection == loadedSection {
            loadedDetail
        } else {
            SectionNavigationPlaceholder(
                section: requestedSection,
                snapshot: sectionSnapshots[requestedSection]
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

    private var sidebarSelection: Binding<SidebarDestination?> {
        Binding(
            get: { navigation.destination },
            set: { destination in
                guard let destination else { return }
                navigation.select(destination)
                guard case .monitoring(let section) = destination,
                      section != requestedSection else { return }
                requestedSection = section
            }
        )
    }

    private func loadRequestedSection() async {
        let target = requestedSection
        guard target != loadedSection else { return }
        let departing = loadedSection

        if target == .agentStorage {
            await Task.yield()
        } else {
            do {
                // Coalesce rapid navigation so only the page the user settles on builds its
                // charts and scrolling hierarchy. The cached placeholder is already visible.
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
        }
        guard !Task.isCancelled, requestedSection == target else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            loadedSection = target
        }

        let departingSnapshot = await SectionPreviewSnapshot.capture(
            section: departing,
            store: store
        )
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
            processes = input.processes
                .sorted { $0.currentCPUPercent > $1.currentCPUPercent }
                .prefix(6)
                .map(ProcessPreviewRow.init)
        } else {
            processes = []
        }

        let volumes: [VolumePreviewRow]
        if input.section == .disks || input.section == .overview {
            volumes = input.volumes.prefix(4).map { volume in
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("应用资源行为正常"))
                            .font(.title2.weight(.semibold))
                        Text(L10n.text("后台持续观察应用的磁盘、CPU 与网络活动"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker(
                        L10n.text("时间范围"),
                        selection: Binding.constant(SampleRange.minute)
                    ) {
                        ForEach(SampleRange.allCases) { range in
                            Text(range.localizedTitle).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 250)
                    Button {} label: {
                        Image(systemName: "pause.fill")
                    }
                }

                HStack(spacing: 14) {
                    overviewMetric("CPU · 最近 5 秒", "00.0%", "cpu", .blue)
                    Divider().frame(height: 42)
                    overviewMetric("磁盘写入 · 最近 5 秒", "0.00 MB/s", "pencil.line", .orange)
                    Divider().frame(height: 42)
                    overviewMetric("网络 · 最近 5 秒", "0.00 MB/s", "network", .green)
                    Divider().frame(height: 42)
                    overviewMetric("可见应用", "000", "square.stack.3d.up", .purple)
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeading(
                        L10n.text("磁盘实时"),
                        subtitle: L10n.text("最近 5 秒的设备读写，按挂载卷名称展示")
                    )
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 280), spacing: 20)],
                        alignment: .leading,
                        spacing: 0
                    ) {
                        ForEach(previewVolumes) { volume in
                            overviewVolumeRow(volume)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeading(
                        L10n.text("资源趋势"),
                        subtitle: L10n.text("物理设备吞吐，读取实线、写入虚线")
                    ) {
                        Picker(
                            L10n.text("资源"),
                            selection: Binding.constant("disk")
                        ) {
                            Text(L10n.text("磁盘 I/O")).tag("disk")
                            Text("CPU").tag("cpu")
                            Text(L10n.text("网络")).tag("network")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 250)
                    }
                    overviewChartPlaceholder
                }

                Divider()

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("正在活动的应用"))
                                .font(.headline)
                            Text(L10n.text("一个应用的磁盘、CPU 与网络行为汇总在同一处"))
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
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 28)
            .redacted(reason: .placeholder)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func overviewMetric(
        _ title: String,
        _ value: String,
        _ symbol: String,
        _ color: Color
    ) -> some View {
        MetricValue(title: title, value: value, symbol: symbol, color: color)
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
                    .foregroundStyle(.teal)
                Text(ByteRateFormatter.rate(volume.writeRate))
                    .foregroundStyle(.orange)
            }
            .font(.caption.monospaced().weight(.medium))
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var overviewChartPlaceholder: some View {
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
        .frame(height: 176)
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
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    processRangePlaceholder(showsLabel: true)
                    Spacer(minLength: 16)
                    processSearchPlaceholder
                    EvidenceLabel(
                        text: "I/O · CPU · 网络 · 当前用户可见",
                        symbol: "person.crop.circle.badge.checkmark"
                    )
                }

                HStack(spacing: 12) {
                    processRangePlaceholder(showsLabel: false)
                    Spacer(minLength: 8)
                    processSearchPlaceholder
                }
            }
            .frame(height: 32)
            .padding(16)

            Divider()
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func processRangePlaceholder(showsLabel: Bool) -> some View {
        HStack(spacing: 10) {
            if showsLabel {
                Text(L10n.text("时间范围"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Picker("", selection: Binding.constant(SampleRange.minute)) {
                ForEach(SampleRange.allCases) { range in
                    Text(range.localizedTitle).tag(range)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 260)
        }
        .fixedSize(horizontal: true, vertical: false)
        .redacted(reason: .placeholder)
        .disabled(true)
    }

    private var processSearchPlaceholder: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            Text(L10n.text("搜索应用或进程"))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(width: 240, height: 28)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .redacted(reason: .placeholder)
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
            return (0..<6).map(ProcessPreviewRow.placeholder)
        }
        return processes
    }

    private var previewVolumes: [VolumePreviewRow] {
        guard let volumes = snapshot?.volumes, !volumes.isEmpty else {
            return (0..<4).map {
                VolumePreviewRow(
                    id: "placeholder-\($0)",
                    name: "Mounted volume",
                    readRate: 0,
                    writeRate: 0
                )
            }
        }
        return volumes
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
        .frame(height: 34)
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
        .frame(height: 56)
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
