import AppKit
import FindDiskKillerCore
import Observation
import SwiftUI

struct ProcessDetailPresentation: Identifiable {
    let process: ProcessActivity
    let updatesLive: Bool

    var id: ProcessActivity.ID { process.id }
}

@MainActor
@Observable
final class ProcessDetailWindowCoordinator {
    private var presentations: [ProcessActivity.ID: ProcessDetailPresentation] = [:]
    @ObservationIgnored private var activationTask: Task<Void, Never>?
    @ObservationIgnored private var requestedProcessID: ProcessActivity.ID?

    func present(_ presentation: ProcessDetailPresentation) {
        presentations[presentation.id] = presentation
        requestedProcessID = presentation.id
    }

    func presentation(for processID: ProcessActivity.ID) -> ProcessDetailPresentation? {
        presentations[processID]
    }

    func remove(_ processID: ProcessActivity.ID) {
        presentations.removeValue(forKey: processID)
    }

    func activate(_ presentation: ProcessDetailPresentation) {
        requestedProcessID = presentation.id
        activationTask?.cancel()
        activationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for delay in [0, 45, 110, 220] {
                if delay > 0 {
                    try? await Task.sleep(for: .milliseconds(delay))
                } else {
                    await Task.yield()
                }
                guard !Task.isCancelled, requestedProcessID == presentation.id else { return }
                promoteWindow(for: presentation)
            }
        }
    }

    func register(_ window: NSWindow, for processID: ProcessActivity.ID) {
        window.identifier = Self.windowIdentifier(for: processID)
        guard requestedProcessID == processID,
              let presentation = presentations[processID]
        else { return }
        promoteWindow(for: presentation)
    }

    private func promoteWindow(for presentation: ProcessDetailPresentation) {
        let identifier = Self.windowIdentifier(for: presentation.id)
        let window = NSApp.windows.first { $0.identifier == identifier }
            ?? NSApp.windows.first {
                $0.identifier?.rawValue != "main"
                    && $0.title == presentation.process.localizedDisplayName
            }
        guard let window else { return }
        window.level = .normal
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func windowIdentifier(
        for processID: ProcessActivity.ID
    ) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("process-detail-\(processID)")
    }
}

private enum OverviewMetric: String, CaseIterable, Identifiable {
    case disk = "磁盘 I/O"
    case cpu = "CPU"
    case network = "网络"
    case memory = "内存"

    var id: String { rawValue }
    var title: String { L10n.text(rawValue) }
}

struct OverviewDiskLayout: Equatable {
    static let maximumVisibleVolumeRows = 5
    static let standardVolumeRowHeight: CGFloat = 40
    static let singleVolumeRowHeight: CGFloat = 68
    static let summaryHeight: CGFloat = 108
    static let leadValueHeight: CGFloat = 78

    let volumeCount: Int

    var visibleRowCount: Int {
        min(max(volumeCount, 1), Self.maximumVisibleVolumeRows)
    }

    var rowHeight: CGFloat {
        volumeCount == 1 ? Self.singleVolumeRowHeight : Self.standardVolumeRowHeight
    }

    var volumeViewportHeight: CGFloat {
        volumeCount == 1
            ? Self.singleVolumeRowHeight
            : CGFloat(visibleRowCount) * Self.standardVolumeRowHeight
    }

    var contentHeight: CGFloat {
        Self.leadValueHeight + volumeViewportHeight + Self.summaryHeight
    }

    var isScrollable: Bool {
        volumeCount > Self.maximumVisibleVolumeRows
    }
}

enum OverviewLayoutContract {
    static let metricColumnCount = 3
    static let metricTileCount = 6
    static let applicationRowLimit = 12
    static let contentSpacing: CGFloat = 12
    static let metricSpacing: CGFloat = 10
    static let pageTopPadding: CGFloat = 14
    static let pageBottomPadding: CGFloat = 24
    static let resourceControlWidth: CGFloat = 320
    static let networkMetricBarCount = 18
}

struct NetworkBarSample: Equatable {
    let timestamp: Date
    let receive: Double?
    let send: Double?
}

struct NetworkBarBucket: Equatable {
    let receive: Double?
    let send: Double?
}

func networkBarBuckets(
    samples: [NetworkBarSample],
    endingAt end: Date,
    windowDuration: TimeInterval,
    bucketCount: Int
) -> [NetworkBarBucket] {
    let count = max(bucketCount, 1)
    let duration = max(windowDuration, 1)
    let start = end.addingTimeInterval(-duration)
    var buckets = Array(
        repeating: NetworkBarBucket(receive: nil, send: nil),
        count: count
    )

    for sample in samples {
        guard sample.timestamp >= start,
              sample.timestamp <= end
        else { continue }

        let progress = sample.timestamp.timeIntervalSince(start) / duration
        let index = min(count - 1, max(0, Int(progress * Double(count))))
        let current = buckets[index]
        buckets[index] = NetworkBarBucket(
            receive: maxFinite(current.receive, sample.receive),
            send: maxFinite(current.send, sample.send)
        )
    }

    return buckets
}

private func maxFinite(_ current: Double?, _ next: Double?) -> Double? {
    let values = [current, next].compactMap { value -> Double? in
        guard let value, value.isFinite else { return nil }
        return max(value, 0)
    }
    return values.max()
}

struct OverviewView: View {
    let store: MonitorStore
    let processDetailWindows: ProcessDetailWindowCoordinator
    @Environment(\.openWindow) private var openWindow
    @State private var selectedProcessID: ProcessActivity.ID?
    @State private var selectedMetric: OverviewMetric = .disk
    @State private var frozenAt: Date?
    @State private var frozenProcesses: [ProcessActivity] = []
    @State private var frozenSystemLayerActivity: SystemLayerActivity?
    @State private var processHoverCoordinator = ProcessHoverCoordinator()

    var body: some View {
        ZStack {
            InstrumentCanvas()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: OverviewLayoutContract.contentSpacing) {
                    overviewHeader
                    metricStrip
                    diskActivitySection
                    applicationSection
                }
                .padding(.horizontal, InstrumentDesign.Spacing.page)
                .padding(.top, OverviewLayoutContract.pageTopPadding)
                .padding(.bottom, OverviewLayoutContract.pageBottomPadding)
            }
        }
    }

    private var overviewHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 18) {
                diagnosticIdentity
                Spacer(minLength: 12)
                rangeControl
                liveControls
            }

            VStack(alignment: .leading, spacing: 10) {
                diagnosticIdentity
                HStack(spacing: 12) {
                    rangeControl
                    Spacer(minLength: 4)
                    liveControls
                }
            }
        }
        .frame(minHeight: 62)
    }

    private var diagnosticIdentity: some View {
        HStack(alignment: .center, spacing: 26) {
            Text(L10n.text("诊断"))
                .font(.system(size: 26, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.72)
                if store.selectedCoverage < 0.999 {
                    EvidenceLabel(
                        text: L10n.format("已观测 %d%%", Int(store.selectedCoverage * 100)),
                        symbol: "clock.badge.exclamationmark"
                    )
                }
            }
        }
        .frame(width: InstrumentDesign.Layout.diagnosticIdentityWidth, alignment: .leading)
    }

    private var rangeControl: some View {
        GlassSegmentedControl("时间范围", selection: Bindable(store).selectedRange) {
            ForEach(SampleRange.allCases) { range in
                Text(range.localizedTitle).tag(range)
            }
        }
        .frame(width: 224)
    }

    private var liveControls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Circle()
                    .fill(healthColor.opacity(0.90))
                    .frame(width: 7, height: 7)
                    .overlay {
                        Circle().stroke(healthColor.opacity(0.24), lineWidth: 4)
                    }
                    .accessibilityHidden(true)
                Text(L10n.text("现在"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Button {
                toggleLiveFollowing()
            } label: {
                Image(systemName: store.isFollowingLive ? "pause.fill" : "play.fill")
            }
            .buttonStyle(AppIconButtonStyle(size: 32))
            .help(L10n.text(store.isFollowingLive ? "暂停实时跟随" : "返回实时"))
        }
    }

    private var metricStrip: some View {
        metricGrid(columnCount: OverviewLayoutContract.metricColumnCount)
    }

    private func metricGrid(columnCount: Int) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(
                    .flexible(minimum: 0),
                    spacing: OverviewLayoutContract.metricSpacing
                ),
                count: columnCount
            ),
            spacing: OverviewLayoutContract.metricSpacing
        ) {
            metricCards
        }
    }

    @ViewBuilder
    private var metricCards: some View {
        cpuMetric
        diskMetric
        networkMetric
        memoryMetric
        volumeMetric
        applicationMetric
    }

    private var cpuMetric: some View {
        GlassMetricTile(
            title: "CPU · 最近 5 秒",
            symbol: "cpu",
            accent: InstrumentDesign.ColorRole.cpu,
            accessibilitySummary: store.isSystemCPUAvailable
                ? L10n.format("CPU 当前 %@", PercentFormatter.cpu(store.currentCPUPercent))
                : L10n.text("CPU 采样缺口")
        ) {
            DataValue(
                value: store.isSystemCPUAvailable
                    ? formattedNumber(store.currentCPUPercent, fractionDigits: 1)
                    : L10n.text("采样缺口"),
                unit: store.isSystemCPUAvailable ? "%" : nil
            )
        } visualization: {
            CPUCoreEnergyBars(cores: store.cpuCoreUsages)
        }
    }

    private var diskMetric: some View {
        GlassMetricTile(
            title: "磁盘写入 · 最近 5 秒",
            symbol: "internaldrive",
            accent: InstrumentDesign.ColorRole.diskWrite,
            accessibilitySummary: store.isDiskAvailable
                ? L10n.format("磁盘写入当前 %@", ByteRateFormatter.rate(store.currentWriteRate))
                : L10n.text("磁盘采样缺口")
        ) {
            formattedDataValue(
                store.isDiskAvailable
                    ? ByteRateFormatter.rate(store.currentWriteRate)
                    : L10n.text("采样缺口")
            )
        } visualization: {
            DiskIOSparkline(
                read: visibleDiskPoints.map(\.readBytesPerSecond),
                write: visibleDiskPoints.map(\.writeBytesPerSecond),
                capacity: metricTimelineCapacity
            )
        }
    }

    private var networkMetric: some View {
        GlassMetricTile(
            title: "网络 · 最近 5 秒",
            symbol: "wifi",
            accent: InstrumentDesign.ColorRole.read,
            accessibilitySummary: store.isSystemNetworkAvailable
                ? L10n.format(
                    "网络当前下载 %@，上传 %@",
                    ByteRateFormatter.rate(store.currentNetworkReceiveRate),
                    ByteRateFormatter.rate(store.currentNetworkSendRate)
                )
                : L10n.text("网络采样缺口")
        ) {
            formattedDataValue(
                store.isSystemNetworkAvailable
                    ? ByteRateFormatter.rate(
                        store.currentNetworkReceiveRate + store.currentNetworkSendRate
                    )
                    : L10n.text("采样缺口")
            )
        } visualization: {
            let buckets = networkMetricBuckets
            BidirectionalNetworkBars(
                receive: buckets.map(\.receive),
                send: buckets.map(\.send),
                capacity: OverviewLayoutContract.networkMetricBarCount
            )
        }
    }

    private var memoryMetric: some View {
        GlassMetricTile(
            title: "内存",
            symbol: "memorychip",
            accent: InstrumentDesign.ColorRole.memory,
            accessibilitySummary: memoryAccessibilitySummary
        ) {
            formattedDataValue(
                store.isSystemMemoryAvailable
                    ? ByteRateFormatter.bytes(store.currentMemoryUsedBytes)
                    : L10n.text("采样缺口")
            )
        } visualization: {
            ViewThatFits(in: .horizontal) {
                memoryVisualization(donutSize: 62)
                    .frame(minWidth: 225)
                memoryVisualization(donutSize: 42)
            }
        }
    }

    private var volumeMetric: some View {
        GlassMetricTile(
            title: "卷容量",
            symbol: "externaldrive.connected.to.line.below",
            accent: InstrumentDesign.ColorRole.healthy,
            accessibilitySummary: L10n.format("当前监控 %d 个本地卷", visibleVolumes.count)
        ) {
            DataValue(value: L10n.number(visibleVolumes.count), unit: L10n.text("个卷"))
        } visualization: {
            VStack(alignment: .leading, spacing: 6) {
                SegmentedEnergyMeter(
                    fraction: visibleVolumes.map(\.usedFraction).max() ?? 0,
                    color: InstrumentDesign.ColorRole.healthy,
                    threshold: 0.9
                )
                .frame(height: 14)
                ForEach(Array(visibleVolumes.prefix(2))) { volume in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(InstrumentDesign.ColorRole.healthy.opacity(0.78))
                            .frame(width: 6, height: 6)
                        Text(volume.name)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(PercentFormatter.cpu(volume.usedFraction * 100))
                            .monospacedDigit()
                            .minimumScaleFactor(0.68)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var applicationMetric: some View {
        GlassMetricTile(
            title: "可见应用",
            symbol: "square.stack.3d.up",
            accent: InstrumentDesign.ColorRole.memory,
            accessibilitySummary: L10n.format(
                "当前可见 %d 个应用，%d 个进程",
                store.activeApplicationCount,
                store.visibleProcessCount
            )
        ) {
            DataValue(value: L10n.number(store.activeApplicationCount), unit: nil)
        } visualization: {
            VStack(alignment: .leading, spacing: 8) {
                SegmentedEnergyMeter(
                    fraction: Double(store.activeApplicationCount)
                        / Double(max(store.visibleProcessCount, 1)),
                    color: InstrumentDesign.ColorRole.memory,
                    segments: 8
                )
                .frame(height: 13)
                Text(L10n.format("%d 个进程", store.visibleProcessCount))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var diskActivitySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading("磁盘活动", subtitle: "最近 5 秒的设备读写，按挂载卷名称展示") {
                GlassSegmentedControl("资源", selection: $selectedMetric) {
                    ForEach(OverviewMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .frame(width: OverviewLayoutContract.resourceControlWidth)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    volumeColumn
                        .frame(minWidth: 270, idealWidth: 310, maxWidth: 340)

                    Divider()

                    trendChart
                        .frame(minWidth: 430, maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 14) {
                    volumeColumn
                    Divider()
                    trendChart
                }
            }
        }
        .overviewPanel()
    }

    private var applicationSection: some View {
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

            ProcessTable(
                processes: displayedProcesses,
                systemLayerActivity: displayedSystemLayerActivity,
                selectedProcessID: selectedProcessID,
                limit: 12,
                hoverCoordinator: processHoverCoordinator,
                onSelect: presentProcess,
                isLoading: store.lastUpdatedAt == nil
            )
        }
        .overviewPanel(horizontalPadding: 16, verticalPadding: 14)
    }

    private var volumeList: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(visibleVolumes) { volume in
                    VolumeIOItem(
                        volume: volume,
                        disks: physicalDisks(for: volume),
                        sharesDevice: sharesPhysicalDevice(volume)
                    )
                    .frame(height: resolvedVolumeRowHeight)
                }
            }
        }
        .scrollDisabled(!diskLayout.isScrollable)
        .scrollIndicators(diskLayout.isScrollable ? .visible : .hidden)
        .frame(height: diskLayout.volumeViewportHeight, alignment: .top)
    }

    private var volumeColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                formattedDataValue(
                    store.isDiskAvailable
                        ? ByteRateFormatter.rate(store.currentWriteRate)
                        : L10n.text("采样缺口"),
                    size: 44
                )
                Text(L10n.text("当前写入"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(height: OverviewDiskLayout.leadValueHeight, alignment: .topLeading)
            volumeList
            DiskThroughputSummary(
                readRate: visibleDiskSourcePoints.last?.readBytesPerSecond,
                writeRate: visibleDiskSourcePoints.last?.writeBytesPerSecond,
                peakWriteRate: visibleDiskSourcePoints.compactMap(\.writeBytesPerSecond).max()
            )
            .frame(height: OverviewDiskLayout.summaryHeight, alignment: .top)
        }
        .frame(height: diskLayout.contentHeight, alignment: .top)
    }

    @ViewBuilder
    private var trendChart: some View {
        switch selectedMetric {
        case .disk:
            MonitorChart(
                points: visibleDiskPoints,
                height: diskLayout.contentHeight,
                warningThreshold: MonitorStore.elevatedDeviceWriteRate,
                windowDuration: store.selectedRange.seconds
            )
        case .cpu:
            SystemCPUChart(
                points: visibleSystemPoints,
                height: diskLayout.contentHeight,
                windowDuration: store.selectedRange.seconds
            )
        case .network:
            SystemNetworkChart(
                points: visibleSystemPoints,
                height: diskLayout.contentHeight,
                windowDuration: store.selectedRange.seconds
            )
        case .memory:
            SystemMemoryChart(
                points: visibleSystemPoints,
                height: diskLayout.contentHeight,
                windowDuration: store.selectedRange.seconds
            )
        }
    }

    private var resolvedVolumeRowHeight: CGFloat {
        diskLayout.rowHeight
    }

    private var diskLayout: OverviewDiskLayout {
        OverviewDiskLayout(volumeCount: visibleVolumes.count)
    }

    private var visibleDiskPoints: [ThroughputPoint] {
        downsampledChartPoints(visibleDiskSourcePoints, segment: { $0.segment }) {
            [$0.readBytesPerSecond, $0.writeBytesPerSecond]
        }
    }

    private var metricTimelineCapacity: Int {
        min(
            360,
            max(2, Int(ceil(store.selectedRange.seconds / store.samplingInterval)) + 1)
        )
    }

    private var visibleDiskSourcePoints: [ThroughputPoint] {
        let end = frozenAt ?? Date()
        let cutoff = end.addingTimeInterval(-store.selectedRange.seconds)
        return store.points.filter { $0.timestamp >= cutoff && $0.timestamp <= end }
    }

    private var visibleSystemPoints: [SystemResourcePoint] {
        switch selectedMetric {
        case .cpu:
            return downsampledChartPoints(visibleSystemSourcePoints, segment: { $0.cpuSegment }) {
                [$0.cpuPercent]
            }
        case .network:
            return downsampledChartPoints(visibleSystemSourcePoints, segment: { $0.networkSegment }) {
                [$0.networkReceiveBytesPerSecond, $0.networkSendBytesPerSecond]
            }
        case .memory:
            return downsampledChartPoints(visibleSystemSourcePoints, segment: { $0.memorySegment }) {
                [$0.memoryUsedBytes.map(Double.init), $0.memoryCompressedBytes.map(Double.init)]
            }
        case .disk:
            return []
        }
    }

    private var visibleSystemSourcePoints: [SystemResourcePoint] {
        let end = frozenAt ?? Date()
        let cutoff = end.addingTimeInterval(-store.selectedRange.seconds)
        return store.systemPoints.filter { $0.timestamp >= cutoff && $0.timestamp <= end }
    }

    private var networkMetricBuckets: [NetworkBarBucket] {
        let points = store.systemPoints
        let end = frozenAt ?? points.last?.timestamp ?? Date()
        return networkBarBuckets(
            samples: points.map {
                NetworkBarSample(
                    timestamp: $0.timestamp,
                    receive: $0.networkReceiveBytesPerSecond,
                    send: $0.networkSendBytesPerSecond
                )
            },
            endingAt: end,
            windowDuration: store.selectedRange.seconds,
            bucketCount: OverviewLayoutContract.networkMetricBarCount
        )
    }

    private var cpuSparklineValues: [Double?] {
        downsampledChartPoints(visibleSystemSourcePoints, segment: { $0.cpuSegment }) {
            [$0.cpuPercent]
        }
        .map(\.cpuPercent)
    }

    private var networkSparklineValues: [Double?] {
        downsampledChartPoints(visibleSystemSourcePoints, segment: { $0.networkSegment }) {
            [$0.networkReceiveBytesPerSecond, $0.networkSendBytesPerSecond]
        }
        .map { point in
            guard let receive = point.networkReceiveBytesPerSecond,
                  let send = point.networkSendBytesPerSecond
            else { return nil }
            return receive + send
        }
    }

    private var displayedProcesses: [ProcessActivity] {
        let source = store.isFollowingLive ? store.processes : frozenProcesses
        return source.filter { $0.memberCount > 0 }
    }

    private var displayedSystemLayerActivity: SystemLayerActivity? {
        store.isFollowingLive ? store.systemLayerActivity : frozenSystemLayerActivity
    }

    private func presentProcess(_ process: ProcessActivity) {
        selectedProcessID = process.id
        processHoverCoordinator.clearForSelection()
        let presentation = ProcessDetailPresentation(
            process: process,
            updatesLive: store.isFollowingLive
        )
        processDetailWindows.present(presentation)
        openWindow(id: "process-detail", value: process.id)
        processDetailWindows.activate(presentation)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            if selectedProcessID == process.id { selectedProcessID = nil }
        }
    }

    private var visibleVolumes: [VolumeInfo] {
        store.volumes.filter(\.isLocal)
    }

    private var volumeNames: String {
        visibleVolumes.map(\.name).joined(separator: " · ")
    }

    private var memoryAccessibilitySummary: String {
        guard let memory = store.systemMemory else { return L10n.text("内存采样缺口") }
        return L10n.format(
            "内存已用 %@，总计 %@，压缩 %@",
            ByteRateFormatter.bytes(memory.usedBytes),
            ByteRateFormatter.bytes(memory.totalBytes),
            ByteRateFormatter.bytes(memory.compressedBytes)
        )
    }

    private func formattedNumber(_ value: Double, fractionDigits: Int) -> String {
        L10n.decimal(value, fractionDigits: fractionDigits)
    }

    private func formattedDataValue(_ formatted: String, size: CGFloat = 36) -> DataValue {
        let parts = formatted.split(separator: " ", maxSplits: 1).map(String.init)
        return DataValue(
            value: parts.first ?? formatted,
            unit: parts.count > 1 ? parts[1] : nil,
            size: size
        )
    }

    private func memoryLegend(_ title: String, _ bytes: UInt64?, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color.opacity(0.78))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(L10n.text(title))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(bytes.map(ByteRateFormatter.bytes) ?? L10n.text("采样缺口"))
                .monospacedDigit()
        }
        .font(.caption2)
    }

    private func memoryVisualization(donutSize: CGFloat) -> some View {
        HStack(spacing: donutSize > 50 ? 14 : 7) {
            VStack(alignment: .leading, spacing: 3) {
                memoryLegend("已用", store.systemMemory?.usedBytes, InstrumentDesign.ColorRole.memory)
                memoryLegend("缓存", store.systemMemory?.cachedBytes, .secondary)
                memoryLegend("可用", store.systemMemory?.availableBytes, .secondary)
            }
            .minimumScaleFactor(0.68)
            MemoryDonut(
                used: store.currentMemoryUsedBytes,
                total: store.systemMemory?.totalBytes ?? 0,
                color: InstrumentDesign.ColorRole.read
            )
            .frame(width: donutSize, height: donutSize)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func physicalDisks(for volume: VolumeInfo) -> [DiskActivity] {
        store.disks.filter {
            $0.isPhysical && volume.physicalDiskBSDNames.contains($0.bsdName)
        }
    }

    private func sharesPhysicalDevice(_ volume: VolumeInfo) -> Bool {
        visibleVolumes.contains { other in
            other.id != volume.id
                && !Set(other.physicalDiskBSDNames)
                    .isDisjoint(with: volume.physicalDiskBSDNames)
        }
    }

    private var trendSubtitle: String {
        switch selectedMetric {
        case .disk: L10n.text("物理设备吞吐，读取实线、写入虚线")
        case .cpu: L10n.text("整机 CPU 使用率")
        case .network: L10n.text("物理外部接口，下载实线、上传虚线")
        case .memory: L10n.text("整机已用内存与压缩内存")
        }
    }

    private func toggleLiveFollowing() {
        if store.isFollowingLive {
            frozenAt = Date()
            frozenProcesses = store.processes
            frozenSystemLayerActivity = store.systemLayerActivity
            store.isFollowingLive = false
        } else {
            frozenAt = nil
            frozenProcesses = []
            frozenSystemLayerActivity = nil
            store.isFollowingLive = true
        }
    }

    private var headerTitle: String {
        switch store.health {
        case .elevated: L10n.text("发现持续磁盘活动")
        case .stopped: L10n.text("采集已停止")
        case .unavailable: L10n.text("采集需要处理")
        case .starting: L10n.text("正在建立采样")
        case .normal: L10n.text("这台 Mac 运行正常")
        }
    }

    private var headerSubtitle: String {
        if let top = store.topWriter, top.currentWriteBytesPerSecond > 0 {
            return L10n.format(
                "%@ 当前写入最高 · %@",
                top.localizedDisplayName,
                ByteRateFormatter.rate(top.currentWriteBytesPerSecond)
            )
        }
        if let top = store.topCPUProcess, top.currentCPUPercent >= 1 {
            return L10n.format(
                "%@ 当前最活跃 · CPU %@",
                top.localizedDisplayName,
                PercentFormatter.cpu(top.currentCPUPercent)
            )
        }
        return L10n.text("后台持续观察应用的磁盘、CPU 与网络活动")
    }

    private var healthColor: Color {
        switch store.health {
        case .normal: InstrumentDesign.ColorRole.healthy
        case .elevated: InstrumentDesign.ColorRole.write
        case .starting: InstrumentDesign.ColorRole.cpu
        case .stopped: .secondary
        case .unavailable: InstrumentDesign.ColorRole.warning
        }
    }

    private var healthSymbol: String {
        switch store.health {
        case .normal: "checkmark"
        case .elevated: "exclamationmark"
        case .starting: "ellipsis"
        case .stopped: "pause.fill"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }
}

private struct OverviewMetricCard: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color
    let sparkline: [Double?]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 40, height: 40)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text(title))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(L10n.text(value))
                    .font(.system(.title3, design: .monospaced, weight: .semibold))
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if sparkline.contains(where: { $0 != nil }) {
                MetricSparkline(values: sparkline, color: color)
                    .frame(width: 72, height: 28)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .frame(minWidth: 180, maxWidth: .infinity, minHeight: 82)
        .overviewPanel(horizontalPadding: 0, verticalPadding: 0)
        .accessibilityElement(children: .combine)
    }
}

private struct MetricSparkline: View {
    let values: [Double?]
    let color: Color

    var body: some View {
        Canvas { context, size in
            let finiteValues = values.compactMap { value in
                guard let value, value.isFinite else { return nil as Double? }
                return value
            }
            guard finiteValues.count > 1,
                  let minimum = finiteValues.min(),
                  let maximum = finiteValues.max()
            else { return }

            let valueRange = max(maximum - minimum, maximum * 0.08, 1)
            let widthStep = size.width / CGFloat(max(values.count - 1, 1))
            var path = Path()
            var isDrawing = false

            for (index, value) in values.enumerated() {
                guard let value, value.isFinite else {
                    isDrawing = false
                    continue
                }
                let x = CGFloat(index) * widthStep
                let normalized = (value - minimum) / valueRange
                let y = size.height - CGFloat(normalized) * max(size.height - 2, 1) - 1
                let point = CGPoint(x: x, y: y)
                if isDrawing {
                    path.addLine(to: point)
                } else {
                    path.move(to: point)
                    isDrawing = true
                }
            }

            context.stroke(path, with: .color(color), lineWidth: 1.6)
        }
    }
}

private struct DiskThroughputSummary: View {
    let readRate: Double?
    let writeRate: Double?
    let peakWriteRate: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()

            Label(L10n.text("物理设备总吞吐"), systemImage: "internaldrive")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 8) {
                value(
                    "读取",
                    readRate,
                    color: InstrumentDesign.ColorRole.diskRead,
                    stackAlignment: .leading,
                    frameAlignment: .leading
                )
                value(
                    "写入",
                    writeRate,
                    color: InstrumentDesign.ColorRole.diskWrite,
                    stackAlignment: .center,
                    frameAlignment: .center
                )
                value(
                    "写入峰值",
                    peakWriteRate,
                    color: .secondary,
                    stackAlignment: .trailing,
                    frameAlignment: .trailing
                )
            }
            .frame(maxWidth: .infinity)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    DiskLineLegend()
                    Spacer(minLength: 12)
                    EvidenceLabel(text: "虚拟磁盘不计入总量", symbol: "checkmark.shield")
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 3) {
                    DiskLineLegend()
                    EvidenceLabel(text: "虚拟磁盘不计入总量", symbol: "checkmark.shield")
                }
            }
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func value(
        _ title: String,
        _ rate: Double?,
        color: Color,
        stackAlignment: HorizontalAlignment,
        frameAlignment: Alignment
    ) -> some View {
        VStack(alignment: stackAlignment, spacing: 2) {
            Text(L10n.text(title))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(rate.map(ByteRateFormatter.rate) ?? L10n.text("采样缺口"))
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(color)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }
}

private struct DiskLineLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            item("读取", color: InstrumentDesign.ColorRole.diskRead, dash: [])
            item("写入", color: InstrumentDesign.ColorRole.diskWrite, dash: [])
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("读取实线、写入虚线"))
    }

    private func item(_ title: String, color: Color, dash: [CGFloat]) -> some View {
        HStack(spacing: 4) {
            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: 1.7, lineCap: .round, dash: dash)
                )
            }
            .frame(width: 24, height: 8)
            .accessibilityHidden(true)

            Text(L10n.text(title))
                .lineLimit(1)
        }
    }
}

extension View {
    func overviewPanel(
        horizontalPadding: CGFloat = 16,
        verticalPadding: CGFloat = 14
    ) -> some View {
        GlassSurface(
            cornerRadius: InstrumentDesign.Radius.panel,
            padding: 0
        ) {
            padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
        }
    }
}

private struct VolumeIOItem: View {
    let volume: VolumeInfo
    let disks: [DiskActivity]
    let sharesDevice: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: volume.isRemovable ? "externaldrive" : "internaldrive")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 1) {
                Text(volume.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(deviceDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if disks.isEmpty {
                Text(L10n.text("吞吐暂不可用"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                HStack(spacing: 10) {
                    rate(L10n.text("读"), readRate, color: InstrumentDesign.ColorRole.diskRead)
                    rate(L10n.text("写"), writeRate, color: InstrumentDesign.ColorRole.diskWrite)
                }
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }

    private var readRate: Double {
        disks.reduce(0) { $0 + $1.readBytesPerSecond }
    }

    private var writeRate: Double {
        disks.reduce(0) { $0 + $1.writeBytesPerSecond }
    }

    private var deviceDescription: String {
        if disks.isEmpty { return volume.mountPath }
        if sharesDevice { return L10n.text("与其他卷共享设备") }
        if disks.count > 1 { return L10n.text("存储集合") }
        return L10n.text("设备实时吞吐")
    }

    private func rate(_ label: String, _ value: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
            Text(ByteRateFormatter.rate(value))
                .monospacedDigit()
        }
            .font(.caption.monospaced().weight(.medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }
}

struct ProcessHoverPresentation {
    let process: ProcessActivity
}

@MainActor
@Observable
final class ProcessHoverCoordinator {
    var presentation: ProcessHoverPresentation?
    var frozenProcesses: [ProcessActivity]?
    var frozenSystemLayerActivity: SystemLayerActivity?
    private(set) var interaction = ProcessHoverInteractionState()

    @ObservationIgnored private var pendingShowTask: Task<Void, Never>?
    @ObservationIgnored private var pendingDismissTask: Task<Void, Never>?

    var activeProcessID: ProcessActivity.ID? {
        interaction.activeProcessID
    }

    func tableHoverChanged(
        _ isHovered: Bool,
        processes: [ProcessActivity],
        systemLayerActivity: SystemLayerActivity?
    ) {
        if isHovered {
            if frozenProcesses == nil {
                frozenProcesses = processes
                frozenSystemLayerActivity = systemLayerActivity
            }
        } else if let activeProcessID {
            endHover(for: activeProcessID)
        } else if presentation == nil {
            frozenProcesses = nil
            frozenSystemLayerActivity = nil
        }
    }

    func enterOrMove(
        process: ProcessActivity,
        processes: [ProcessActivity]
    ) {
        if interaction.suppressedProcessID == process.id { return }
        if interaction.activeProcessID == process.id { return }
        if frozenProcesses == nil {
            frozenProcesses = processes
        }

        switch interaction.enter(process.id) {
        case .suppressed:
            return
        case .stayed:
            return
        case let .changed(generation):
            cancelTasks()
            presentation = nil
            pendingShowTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(320))
                guard !Task.isCancelled, let self else { return }
                guard self.interaction.publish(
                    processID: process.id,
                    generation: generation
                ) else { return }
                self.presentation = ProcessHoverPresentation(process: process)
            }
        }
    }

    func endHover(for processID: ProcessActivity.ID) {
        switch interaction.end(processID) {
        case .ignored, .suppressionCleared:
            return
        case let .scheduleDismiss(generation):
            pendingShowTask?.cancel()
            pendingShowTask = nil
            pendingDismissTask?.cancel()
            pendingDismissTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled, let self,
                      self.interaction.dismissIfIdle(generation: generation)
                else { return }
                self.presentation = nil
                self.frozenProcesses = nil
                self.frozenSystemLayerActivity = nil
            }
        }
    }

    func suppressUntilExit(_ processID: ProcessActivity.ID) {
        cancelTasks()
        interaction.suppressUntilExit(processID)
        presentation = nil
        frozenProcesses = nil
        frozenSystemLayerActivity = nil
    }

    func clearForSelection() {
        cancelTasks()
        interaction.clearForSelection()
        presentation = nil
        frozenProcesses = nil
        frozenSystemLayerActivity = nil
    }

    func popoverDismissed(for processID: ProcessActivity.ID) {
        guard presentation?.process.id == processID else { return }
        presentation = nil
    }

    func reset() {
        clearForSelection()
    }

    private func cancelTasks() {
        pendingShowTask?.cancel()
        pendingShowTask = nil
        pendingDismissTask?.cancel()
        pendingDismissTask = nil
    }
}

enum ProcessTableLayoutContract {
    static let headerHeight: CGFloat = 34
    static let rowHeight: CGFloat = 56
    static let loadingRowCount = 6
}

struct ProcessTable: View {
    static let defaultSortKey: ProcessSortKey = .writeCurrent
    static let defaultSortAscending = false

    let processes: [ProcessActivity]
    var systemLayerActivity: SystemLayerActivity?
    let selectedProcessID: ProcessActivity.ID?
    var limit: Int? = nil
    var scrollAxes: Axis.Set = .horizontal
    let hoverCoordinator: ProcessHoverCoordinator
    let onSelect: (ProcessActivity) -> Void
    var isLoading = false
    var emptyStateTitle: String?
    var emptyStateSymbol = "waveform.path.ecg"
    @State private var sortKey: ProcessSortKey = Self.defaultSortKey
    @State private var ascending = Self.defaultSortAscending
    @State private var columnWidths = ProcessColumnWidths.load()
    @State private var availableTableWidth: CGFloat = 0
    @State private var isSystemLayerExplanationPresented = false

    init(
        processes: [ProcessActivity],
        systemLayerActivity: SystemLayerActivity? = nil,
        selectedProcessID: ProcessActivity.ID?,
        limit: Int? = nil,
        scrollAxes: Axis.Set = .horizontal,
        hoverCoordinator: ProcessHoverCoordinator,
        onSelect: @escaping (ProcessActivity) -> Void,
        isLoading: Bool = false,
        emptyStateTitle: String? = nil,
        emptyStateSymbol: String = "waveform.path.ecg"
    ) {
        self.processes = processes
        self.systemLayerActivity = systemLayerActivity
        self.selectedProcessID = selectedProcessID
        self.limit = limit
        self.scrollAxes = scrollAxes
        self.hoverCoordinator = hoverCoordinator
        self.onSelect = onSelect
        self.isLoading = isLoading
        self.emptyStateTitle = emptyStateTitle
        self.emptyStateSymbol = emptyStateSymbol
    }

    var body: some View {
        ScrollView(scrollAxes) {
            VStack(spacing: 0) {
                processColumns(isHeader: true)
                    .padding(.horizontal, 14)
                    .frame(height: ProcessTableLayoutContract.headerHeight)
                Divider()

                if isLoading, activeRows.isEmpty {
                    loadingRows
                } else if activeRows.isEmpty {
                    ContentUnavailableView(
                        emptyStateTitle ?? L10n.text("正在建立应用基线"),
                        systemImage: emptyStateSymbol
                    )
                        .frame(width: tableWidth)
                        .frame(minHeight: 180)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleSortedRows) { row in
                            activeRow(row)
                            Divider().padding(.leading, 8)
                        }
                    }
                }
            }
            .frame(width: tableWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scrollIndicators(.automatic)
        .defaultScrollAnchor(.topLeading)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ProcessTableWidthPreferenceKey.self,
                    value: geometry.size.width
                )
            }
        }
        .onPreferenceChange(ProcessTableWidthPreferenceKey.self) { width in
            guard width.isFinite, width > 0, abs(width - availableTableWidth) > 0.5 else { return }
            availableTableWidth = width
        }
        .onHover { isHovered in
            hoverCoordinator.tableHoverChanged(
                isHovered,
                processes: processes,
                systemLayerActivity: systemLayerActivity
            )
        }
        .onDisappear {
            hoverCoordinator.reset()
        }
    }

    @ViewBuilder
    private func activeRow(_ row: ActiveAppRow) -> some View {
        switch row {
        case let .process(process):
            Button {
                select(process)
            } label: {
                processColumns(process: process)
                    .padding(.horizontal, 14)
                    .frame(height: ProcessTableLayoutContract.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ProcessRowButtonStyle(
                isSelected: selectedProcessID == process.id,
                isHovered: hoverCoordinator.activeProcessID == process.id
            ))
            .frame(height: ProcessTableLayoutContract.rowHeight)
            .accessibilityLabel(process.localizedDisplayName)
            .accessibilityValue(accessibilitySummary(for: process))
            .accessibilityHint(L10n.text("按下打开详情"))
            .onContinuousHover { phase in
                updateContinuousHover(for: process, phase: phase)
            }
            .popover(
                isPresented: popoverBinding(for: process.id),
                attachmentAnchor: .rect(.bounds)
            ) {
                ProcessHoverCard(process: hoverCoordinator.presentation?.process ?? process)
            }
        case let .systemLayer(activity):
            Button {
                isSystemLayerExplanationPresented.toggle()
            } label: {
                systemLayerColumns(activity)
                    .padding(.horizontal, 14)
                    .frame(height: ProcessTableLayoutContract.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(height: ProcessTableLayoutContract.rowHeight)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
            .popover(isPresented: $isSystemLayerExplanationPresented) {
                SystemLayerExplanationView()
            }
            .accessibilityLabel(L10n.text("macOS 与存储层"))
            .accessibilityValue(accessibilitySummary(for: activity))
            .accessibilityHint(L10n.text("按下查看统计口径"))
        }
    }

    private func processColumns(isHeader: Bool = false) -> some View {
        let widths = displayedColumnWidths
        return HStack(spacing: 0) {
            sortButton("应用", key: .name, width: widths[.application])
            resizeHandle(after: .application)
            sortButton("CPU · 5 秒", key: .cpuCurrent, width: widths[.cpu])
            resizeHandle(after: .cpu)
            sortButton("写入总量", key: .writeTotal, width: widths[.writeTotal])
            resizeHandle(after: .writeTotal)
            sortButton("当前写入", key: .writeCurrent, width: widths[.writeCurrent])
            resizeHandle(after: .writeCurrent)
            sortButton("写入峰值", key: .writePeak, width: widths[.writePeak])
            resizeHandle(after: .writePeak)
            sortButton("下载平均", key: .networkDownload, width: widths[.networkDownload])
            resizeHandle(after: .networkDownload)
            sortButton("上传平均", key: .networkUpload, width: widths[.networkUpload])
            resizeHandle(after: .networkUpload)
        }
        .font(.caption.weight(isHeader ? .semibold : .regular))
        .foregroundStyle(.secondary)
    }

    private func processColumns(process: ProcessActivity) -> some View {
        let widths = displayedColumnWidths
        return HStack(spacing: 0) {
            HStack(spacing: 9) {
                ProcessIcon(process: process, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(process.localizedDisplayName)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(process.memberCount > 1
                        ? L10n.format("%d 个进程 · 全盘合计", process.memberCount)
                        : L10n.text("全盘 I/O 合计"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: widths[.application], alignment: .leading)
            .help(process.executablePath)

            columnGap()
            metricText(PercentFormatter.cpu(process.currentCPUPercent), width: widths[.cpu])
            columnGap()
            metricText(ByteRateFormatter.bytes(process.totalWriteBytes), width: widths[.writeTotal])
            columnGap()
            metricText(ByteRateFormatter.rate(process.currentWriteBytesPerSecond), width: widths[.writeCurrent])
            columnGap()
            metricText(ByteRateFormatter.rate(process.peakWriteBytesPerSecond), width: widths[.writePeak])
            columnGap()
            if process.isNetworkAvailable {
                metricText(
                    ByteRateFormatter.rate(process.averageNetworkReceiveBytesPerSecond),
                    width: widths[.networkDownload]
                )
                columnGap()
                metricText(
                    ByteRateFormatter.rate(process.averageNetworkSendBytesPerSecond),
                    width: widths[.networkUpload]
                )
                columnGap()
            } else {
                metricText(L10n.text("缺口"), width: widths[.networkDownload])
                columnGap()
                metricText(L10n.text("缺口"), width: widths[.networkUpload])
                columnGap()
            }
        }
        .font(.callout)
    }

    private func systemLayerColumns(_ activity: SystemLayerActivity) -> some View {
        let widths = displayedColumnWidths
        return HStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text("macOS 与存储层"))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(L10n.text("系统服务、文件系统及无法进一步拆分的活动"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: widths[.application], alignment: .leading)

            columnGap()
            optionalMetric(activity.currentCPUPercent.map(PercentFormatter.cpu), width: widths[.cpu])
            columnGap()
            optionalMetric(activity.totalWriteBytes.map(ByteRateFormatter.bytes), width: widths[.writeTotal])
            columnGap()
            optionalMetric(activity.currentWriteBytesPerSecond.map(ByteRateFormatter.rate), width: widths[.writeCurrent])
            columnGap()
            optionalMetric(activity.peakWriteBytesPerSecond.map(ByteRateFormatter.rate), width: widths[.writePeak])
            columnGap()
            optionalMetric(activity.averageNetworkReceiveBytesPerSecond.map(ByteRateFormatter.rate), width: widths[.networkDownload])
            columnGap()
            optionalMetric(activity.averageNetworkSendBytesPerSecond.map(ByteRateFormatter.rate), width: widths[.networkUpload])
            columnGap()
        }
        .font(.callout)
    }

    private func optionalMetric(_ value: String?, width: CGFloat) -> some View {
        metricText(value ?? L10n.text("缺口"), width: width)
            .foregroundStyle(value == nil ? .secondary : .primary)
    }

    private var loadingRows: some View {
        LazyVStack(spacing: 0) {
            ForEach(0..<ProcessTableLayoutContract.loadingRowCount, id: \.self) { _ in
                loadingProcessColumns
                    .padding(.horizontal, 14)
                    .frame(height: ProcessTableLayoutContract.rowHeight)
                Divider().padding(.leading, 8)
            }
        }
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var loadingProcessColumns: some View {
        let widths = displayedColumnWidths
        return HStack(spacing: 0) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text("应用")).lineLimit(1)
                    Text(L10n.text("全盘 I/O 合计"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: widths[.application], alignment: .leading)

            columnGap()
            metricText("00.0%", width: widths[.cpu])
            columnGap()
            metricText("000 MB", width: widths[.writeTotal])
            columnGap()
            metricText("0.00 MB/s", width: widths[.writeCurrent])
            columnGap()
            metricText("0.00 MB/s", width: widths[.writePeak])
            columnGap()
            metricText("0.00 MB/s", width: widths[.networkDownload])
            columnGap()
            metricText("0.00 MB/s", width: widths[.networkUpload])
            columnGap()
        }
        .font(.callout)
    }

    private func metricText(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: width, alignment: .trailing)
    }

    private func columnGap() -> some View {
        Color.clear.frame(width: ProcessColumn.resizeHandleWidth)
    }

    private func resizeHandle(after column: ProcessColumn) -> some View {
        ProcessColumnResizeHandle(
            width: columnWidths[column],
            limits: column.limits,
            onChange: { columnWidths[column] = $0 },
            onEnd: { columnWidths.save() }
        )
    }

    private var tableWidth: CGFloat {
        displayedColumnWidths.tableWidth
    }

    private var displayedColumnWidths: ProcessColumnWidths {
        columnWidths.adapted(to: availableTableWidth)
    }

    private func sortButton(
        _ title: String,
        key: ProcessSortKey,
        width: CGFloat
    ) -> some View {
        Button {
            if sortKey == key {
                ascending.toggle()
            } else {
                sortKey = key
                ascending = key == .name
            }
        } label: {
            HStack(spacing: 3) {
                if key != .name {
                    Spacer(minLength: 0)
                }
                Text(L10n.text(title))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if sortKey == key {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                if key == .name {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 5)
            .frame(width: width, height: 34, alignment: key == .name ? .leading : .trailing)
            .foregroundStyle(sortKey == key ? Color.primary : Color.secondary)
            .background {
                if sortKey == key {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.055))
                        .padding(.vertical, 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.format("按%@排序", L10n.text(title)))
        .accessibilityLabel(L10n.format("按%@排序", L10n.text(title)))
    }

    private var activeRows: [ActiveAppRow] {
        var rows = processSource.map(ActiveAppRow.process)
        if let systemLayerSource { rows.append(.systemLayer(systemLayerSource)) }
        return rows
    }

    private var systemLayerSource: SystemLayerActivity? {
        hoverCoordinator.frozenProcesses == nil
            ? systemLayerActivity
            : hoverCoordinator.frozenSystemLayerActivity
    }

    private var visibleSortedRows: [ActiveAppRow] {
        Self.visibleRows(activeRows, limit: limit, sortKey: sortKey, ascending: ascending)
    }

    static func visibleRows(
        _ rows: [ActiveAppRow],
        limit: Int?,
        sortKey: ProcessSortKey,
        ascending: Bool
    ) -> [ActiveAppRow] {
        let sorted = rows.sorted { lhs, rhs in
            if sortKey == .name {
                let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if comparison != .orderedSame {
                    return ascending
                        ? comparison == .orderedAscending
                        : comparison == .orderedDescending
                }
                return lhs.id < rhs.id
            }

            switch (lhs.metric(for: sortKey), rhs.metric(for: sortKey)) {
            case let (left?, right?) where left != right:
                return ascending ? left < right : left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.id < rhs.id
            }
        }

        guard let limit, limit >= 0, sorted.count > limit else { return sorted }
        guard limit > 0, let systemLayer = sorted.first(where: \.isSystemLayer) else {
            return Array(sorted.prefix(limit))
        }
        var selected = Array(sorted.prefix(limit))
        if !selected.contains(where: \.isSystemLayer) {
            selected.removeLast()
            selected.append(systemLayer)
            selected.sort { lhs, rhs in
                guard let leftIndex = sorted.firstIndex(where: { $0.id == lhs.id }),
                      let rightIndex = sorted.firstIndex(where: { $0.id == rhs.id })
                else { return lhs.id < rhs.id }
                return leftIndex < rightIndex
            }
        }
        return selected
    }

    private var processSource: [ProcessActivity] {
        hoverCoordinator.frozenProcesses ?? processes
    }

    private func select(_ process: ProcessActivity) {
        hoverCoordinator.clearForSelection()
        onSelect(process)
    }

    private func updateContinuousHover(
        for process: ProcessActivity,
        phase: HoverPhase
    ) {
        switch phase {
        case .active:
            hoverCoordinator.enterOrMove(
                process: process,
                processes: processes
            )
        case .ended:
            hoverCoordinator.endHover(for: process.id)
        }
    }

    private func popoverBinding(for processID: ProcessActivity.ID) -> Binding<Bool> {
        Binding(
            get: {
                hoverCoordinator.activeProcessID == processID
                    && hoverCoordinator.presentation?.process.id == processID
            },
            set: { isPresented in
                if !isPresented {
                    hoverCoordinator.popoverDismissed(for: processID)
                }
            }
        )
    }

    private func accessibilitySummary(for process: ProcessActivity) -> String {
        let assessment = ProcessLoadAssessment.assess(process).title
        return [
            assessment,
            "\(L10n.text("CPU · 5 秒")): \(PercentFormatter.cpu(process.currentCPUPercent))",
            "\(L10n.text("读取")): \(ByteRateFormatter.rate(process.currentReadBytesPerSecond))",
            "\(L10n.text("写入")): \(ByteRateFormatter.rate(process.currentWriteBytesPerSecond))"
        ].joined(separator: ". ")
    }

    private func accessibilitySummary(for activity: SystemLayerActivity) -> String {
        [
            "\(L10n.text("CPU · 5 秒")): \(activity.currentCPUPercent.map(PercentFormatter.cpu) ?? L10n.text("缺口"))",
            "\(L10n.text("写入总量")): \(activity.totalWriteBytes.map(ByteRateFormatter.bytes) ?? L10n.text("缺口"))",
            "\(L10n.text("当前写入")): \(activity.currentWriteBytesPerSecond.map(ByteRateFormatter.rate) ?? L10n.text("缺口"))",
            "\(L10n.text("写入峰值")): \(activity.peakWriteBytesPerSecond.map(ByteRateFormatter.rate) ?? L10n.text("缺口"))",
            "\(L10n.text("下载平均")): \(activity.averageNetworkReceiveBytesPerSecond.map(ByteRateFormatter.rate) ?? L10n.text("缺口"))",
            "\(L10n.text("上传平均")): \(activity.averageNetworkSendBytesPerSecond.map(ByteRateFormatter.rate) ?? L10n.text("缺口"))"
        ].joined(separator: ". ")
    }
}

enum ActiveAppRow: Identifiable {
    case process(ProcessActivity)
    case systemLayer(SystemLayerActivity)

    var id: String {
        switch self {
        case let .process(process): process.id
        case let .systemLayer(activity): activity.id
        }
    }

    var displayName: String {
        switch self {
        case let .process(process): process.localizedDisplayName
        case .systemLayer: L10n.text("macOS 与存储层")
        }
    }

    func metric(for key: ProcessSortKey) -> Double? {
        switch (self, key) {
        case (_, .name): nil
        case let (.process(value), .cpuCurrent): value.currentCPUPercent
        case let (.process(value), .writeTotal): Double(value.totalWriteBytes)
        case let (.process(value), .writeCurrent): value.currentWriteBytesPerSecond
        case let (.process(value), .writePeak): value.peakWriteBytesPerSecond
        case let (.process(value), .networkDownload): value.isNetworkAvailable ? value.averageNetworkReceiveBytesPerSecond : nil
        case let (.process(value), .networkUpload): value.isNetworkAvailable ? value.averageNetworkSendBytesPerSecond : nil
        case let (.systemLayer(value), .cpuCurrent): value.currentCPUPercent
        case let (.systemLayer(value), .writeTotal): value.totalWriteBytes.map(Double.init)
        case let (.systemLayer(value), .writeCurrent): value.currentWriteBytesPerSecond
        case let (.systemLayer(value), .writePeak): value.peakWriteBytesPerSecond
        case let (.systemLayer(value), .networkDownload): value.averageNetworkReceiveBytesPerSecond
        case let (.systemLayer(value), .networkUpload): value.averageNetworkSendBytesPerSecond
        }
    }

    var isSystemLayer: Bool {
        id == SystemLayerActivity.stableID
    }
}

private struct SystemLayerExplanationView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.text("macOS 与存储层"), systemImage: "internaldrive")
                .font(.headline)
            Text(L10n.text("汇总整机与可见应用之间的采样差值，包括受保护的系统服务、文件系统写回及存储层活动。"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("只有可比较的采样才显示数值；缺口不会被当作 0。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }
}

private struct ProcessRowButtonStyle: ButtonStyle {
    let isSelected: Bool
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(backgroundColor(isPressed: configuration.isPressed))
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 3)
                }
            }
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed { return Color.accentColor.opacity(0.20) }
        if isSelected { return Color.accentColor.opacity(0.12) }
        if isHovered { return Color.primary.opacity(0.035) }
        return .clear
    }
}

enum ProcessColumn: String, CaseIterable {
    case application
    case cpu
    case writeTotal
    case writeCurrent
    case writePeak
    case networkDownload
    case networkUpload

    static let resizeHandleWidth: CGFloat = 12
    static let adaptiveApplicationUpperBound: CGFloat = 360

    var defaultWidth: CGFloat {
        switch self {
        case .application: 220
        case .cpu: 92
        case .writeTotal, .writeCurrent, .writePeak: 94
        case .networkDownload, .networkUpload: 96
        }
    }

    var limits: ClosedRange<CGFloat> {
        switch self {
        case .application: 150...420
        case .cpu: 78...150
        default: 82...180
        }
    }

    var defaultsKey: String { "processTableColumnWidth.\(rawValue)" }

    var adaptiveWeight: CGFloat {
        switch self {
        case .application: 0
        case .cpu: 0.85
        case .writeTotal: 1
        case .writeCurrent, .writePeak: 1.05
        case .networkDownload, .networkUpload: 1.1
        }
    }
}

struct ProcessColumnWidths: Equatable {
    private var values: [ProcessColumn: CGFloat]

    static let horizontalPadding: CGFloat = 28

    static var defaults: ProcessColumnWidths {
        ProcessColumnWidths(values: Dictionary(uniqueKeysWithValues: ProcessColumn.allCases.map {
            ($0, $0.defaultWidth)
        }))
    }

    subscript(column: ProcessColumn) -> CGFloat {
        get { values[column] ?? column.defaultWidth }
        set { values[column] = min(max(newValue, column.limits.lowerBound), column.limits.upperBound) }
    }

    static func load(defaults: UserDefaults = .standard) -> ProcessColumnWidths {
        var widths = ProcessColumnWidths.defaults
        for column in ProcessColumn.allCases {
            guard let stored = defaults.object(forKey: column.defaultsKey) as? Double else { continue }
            widths[column] = CGFloat(stored)
        }
        return widths
    }

    func save(defaults: UserDefaults = .standard) {
        for column in ProcessColumn.allCases {
            defaults.set(Double(self[column]), forKey: column.defaultsKey)
        }
    }

    var tableWidth: CGFloat {
        ProcessColumn.allCases.reduce(Self.horizontalPadding) { $0 + self[$1] }
            + CGFloat(ProcessColumn.allCases.count) * ProcessColumn.resizeHandleWidth
    }

    func adapted(to availableWidth: CGFloat) -> ProcessColumnWidths {
        guard availableWidth.isFinite, availableWidth > tableWidth else { return self }

        var resolved = self
        var remaining = availableWidth - tableWidth
        let applicationWidth = self[.application]
        let applicationTarget = min(
            max(applicationWidth, availableWidth * 0.22),
            max(applicationWidth, ProcessColumn.adaptiveApplicationUpperBound)
        )
        let applicationGrowth = min(remaining, max(0, applicationTarget - applicationWidth))
        resolved.values[.application] = applicationWidth + applicationGrowth
        remaining -= applicationGrowth

        let metricColumns = ProcessColumn.allCases.filter { $0 != .application }
        let totalWeight = metricColumns.reduce(CGFloat.zero) { $0 + $1.adaptiveWeight }
        for column in metricColumns {
            resolved.values[column] = self[column] + remaining * column.adaptiveWeight / totalWeight
        }
        return resolved
    }
}

private struct ProcessTableWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ProcessColumnResizeHandle: View {
    let width: CGFloat
    let limits: ClosedRange<CGFloat>
    let onChange: (CGFloat) -> Void
    let onEnd: () -> Void
    @State private var dragStartWidth: CGFloat?
    @State private var isHovered = false
    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(
                isHovered || isDragging
                    ? Color.accentColor.opacity(0.75)
                    : Color.secondary.opacity(0.16)
            )
            .frame(width: 1, height: 20)
            .frame(width: ProcessColumn.resizeHandleWidth, height: 34)
            .contentShape(Rectangle())
            .onHover { isInside in
                isHovered = isInside
                (isInside ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if dragStartWidth == nil { dragStartWidth = width }
                        isDragging = true
                        let proposed = (dragStartWidth ?? width) + value.translation.width
                        onChange(min(max(proposed, limits.lowerBound), limits.upperBound))
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        isDragging = false
                        onEnd()
                    }
            )
    }
}

enum ProcessSortKey: Equatable {
    case name
    case cpuCurrent
    case writeTotal
    case writeCurrent
    case writePeak
    case networkDownload
    case networkUpload
}

struct ProcessDetailSheet: View {
    let store: MonitorStore
    let processID: ProcessActivity.ID
    let updatesLive: Bool
    @State private var process: ProcessActivity
    @State private var chartPoints: [ProcessMetricPoint]
    @State private var chartsReady = false
    @State private var isProcessAvailable = true
    @State private var selectedSection: ProcessDetailSection = .overview
    @State private var fileAccessTrace: FileAccessTraceStore
    @AccessibilityFocusState private var headerIsFocused: Bool

    init(
        store: MonitorStore,
        presentation: ProcessDetailPresentation,
        traceActivityRegistry: TraceActivityRegistry
    ) {
        self.store = store
        processID = presentation.id
        updatesLive = presentation.updatesLive
        _process = State(initialValue: presentation.process)
        _chartPoints = State(initialValue: [])
        _fileAccessTrace = State(initialValue: FileAccessTraceStore(
            activityRegistry: traceActivityRegistry
        ))
    }

    var body: some View {
        detail
            .task {
                headerIsFocused = true
                await runPresentationLifecycle()
            }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            detailHeader

            Divider()

            if selectedSection == .overview {
                overviewContent
            } else {
                ProcessFileActivityView(
                    process: process,
                    volumes: store.volumes,
                    traceStore: fileAccessTrace
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { InstrumentCanvas() }
        .onDisappear {
            fileAccessTrace.stop()
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 18) {
            HStack(spacing: 13) {
                ProcessIcon(process: process, size: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text(process.localizedDisplayName)
                        .font(.system(size: 25, weight: .semibold))
                        .lineLimit(1)
                        .accessibilityFocused($headerIsFocused)
                    Text(process.memberCount == 1
                        ? L10n.format("PID %d", process.pids.first ?? 0)
                        : L10n.format("%d 个进程聚合", process.memberCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)

            GlassSegmentedControl("详情视图", selection: $selectedSection) {
                ForEach(ProcessDetailSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .frame(width: 250)

            EvidenceLabel(
                text: isProcessAvailable ? "当前用户实测" : "应用样本已结束",
                symbol: isProcessAvailable ? "checkmark.circle" : "clock.badge.xmark",
                color: isProcessAvailable ? .green : .secondary
            )
            .frame(minWidth: 150, maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
    }

    private var overviewContent: some View {
        ProcessDetailOverview(
            process: process,
            points: chartPoints,
            chartsReady: chartsReady,
            isProcessAvailable: isProcessAvailable,
            systemMemory: store.systemMemory
        )
    }

    private func runPresentationLifecycle() async {
        await Task.yield()
        guard !Task.isCancelled else { return }

        let initialMetrics = process.metrics
        let initialPoints = await Task.detached(priority: .userInitiated) {
            Self.optimizedChartPoints(initialMetrics)
        }.value
        guard !Task.isCancelled else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            chartPoints = initialPoints
            chartsReady = true
        }

        guard updatesLive else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(max(1, store.samplingInterval)))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let latest = store.processes.first(where: { $0.id == processID }) else {
                withTransaction(transaction) { isProcessAvailable = false }
                continue
            }
            let hasNewSample = latest.lastActivity != process.lastActivity
                || latest.metrics.last?.timestamp != process.metrics.last?.timestamp
            guard hasNewSample || !isProcessAvailable else { continue }
            let points = await Task.detached(priority: .userInitiated) {
                Self.optimizedChartPoints(latest.metrics)
            }.value
            guard !Task.isCancelled else { return }
            withTransaction(transaction) {
                process = latest
                chartPoints = points
                isProcessAvailable = true
            }
        }
    }

    nonisolated private static func optimizedChartPoints(
        _ points: [ProcessMetricPoint]
    ) -> [ProcessMetricPoint] {
        downsampledChartPoints(points, maxCount: 120, segment: { $0.networkSegment }) {
            [
                $0.readBytesPerSecond,
                $0.writeBytesPerSecond,
                $0.cpuPercent,
                $0.networkReceiveBytesPerSecond,
                $0.networkSendBytesPerSecond,
                Double($0.memoryBytes)
            ]
        }
    }
}

enum ProcessDetailSection: String, CaseIterable, Identifiable {
    case overview
    case files

    var id: String { rawValue }
    var title: String { L10n.text(self == .overview ? "概览" : "文件活动") }
}

private struct FileAccessDirectory: Identifiable, Equatable, Sendable {
    let path: String
    let displayName: String
    let volumeName: String
    let modes: Set<OpenFileAccessMode>
    let fileCount: Int
    let lastChangedAt: Date?
    let changeObservationStatus: FileChangeObservationStatus
    let isCurrentlyOpen: Bool

    var id: String { path }
}

private struct TrackedFileLocation: Sendable {
    let row: FileAccessDirectory
    let firstObservedAt: Date
    let lastSeenOpenAt: Date
}

private struct FileActivityRefreshProjection: Sendable {
    let rows: [FileAccessDirectory]
    let trackedLocations: [String: TrackedFileLocation]
    let changesUnavailable: Bool
    let summary: FileActivityRowSummary
}

private struct FileActivityRowSummary: Sendable {
    static let empty = Self(
        writableCount: 0,
        changedCount: 0,
        openFileCount: 0,
        fileCountHistogram: []
    )

    let writableCount: Int
    let changedCount: Int
    let openFileCount: Int
    let fileCountHistogram: [Double]
}

private enum FileActivityFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case writable
    case changed

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: L10n.text("全部")
        case .writable: L10n.text("可写")
        case .changed: L10n.text("最近 5 分钟修改")
        }
    }
}

private enum FileActivitySort: String, CaseIterable, Identifiable, Sendable {
    case name
    case fileCount
    case recentChange

    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: L10n.text("名称")
        case .fileCount: L10n.text("打开文件")
        case .recentChange: L10n.text("最近修改时间")
        }
    }
}

private struct ProcessFileActivityView: View {
    let process: ProcessActivity
    let volumes: [VolumeInfo]
    let traceStore: FileAccessTraceStore
    @State private var snapshot: OpenFileSnapshot?
    @State private var rows: [FileAccessDirectory] = []
    @State private var fileChangesHaveGap = false
    @State private var fileChangesObservedSince: Date?
    @State private var fileChangesUnavailable = false
    @State private var selectedPath: String?
    @State private var filter: FileActivityFilter = .all
    @State private var sort: FileActivitySort = .fileCount
    @State private var searchText = ""
    @State private var visibleRows: [FileAccessDirectory] = []
    @State private var isUpdatingVisibleRows = false
    @State private var visibleRowsTask: Task<Void, Never>?
    @State private var rowSummary = FileActivityRowSummary.empty
    @State private var trackedLocations: [String: TrackedFileLocation] = [:]
    @State private var monitoredSessions: [ProcessSession]
    @State private var monitoredVolumes: [VolumeInfo]
    @State private var isFileActivityHelpPresented = false
    @State private var tracedPath: String?
    @State private var pendingTracePath: String?
    @State private var tracePreparationError: String?
    @State private var tracePreparationTask: Task<Void, Never>?
    @State private var isObservationPaused = false

    init(
        process: ProcessActivity,
        volumes: [VolumeInfo],
        traceStore: FileAccessTraceStore
    ) {
        self.process = process
        self.volumes = volumes
        self.traceStore = traceStore
        _monitoredSessions = State(initialValue: process.sessions)
        _monitoredVolumes = State(initialValue: volumes)
    }

    var body: some View {
        Group {
            if tracedPath != nil {
                FileAccessTraceView(
                    store: traceStore,
                    contextProcessName: process.localizedDisplayName,
                    onBack: {
                        tracePreparationTask?.cancel()
                        pendingTracePath = nil
                        tracePreparationError = nil
                        traceStore.endEphemeralSession()
                        traceStore.removeTarget()
                        tracedPath = nil
                    }
                )
            } else {
                VStack(spacing: 0) {
                    fileActivityHeader
                    Divider()
                    fileActivityContent
                }
            }
        }
        .task(id: volumeTopology) {
            monitoredVolumes = volumes
            rebindRows(to: volumes)
            let lease = await FileChangeWatcher.shared.beginSession(volumes: volumes)
            await refreshLoop()
            await FileChangeWatcher.shared.endSession(lease)
        }
        .onChange(of: process.sessions, initial: true) { _, sessions in
            monitoredSessions = sessions
            traceStore.setProcessSessions(sessions)
        }
        .onChange(of: rows, initial: true) { _, _ in
            scheduleVisibleRowsUpdate()
        }
        .onChange(of: filter) { _, _ in
            scheduleVisibleRowsUpdate(showsProgress: true)
        }
        .onChange(of: sort) { _, _ in
            scheduleVisibleRowsUpdate(showsProgress: true)
        }
        .onChange(of: searchText) { _, _ in
            scheduleVisibleRowsUpdate(debounce: true, showsProgress: true)
        }
        .onDisappear {
            visibleRowsTask?.cancel()
            tracePreparationTask?.cancel()
        }
    }

    private var fileActivityHeader: some View {
        VStack(alignment: .leading, spacing: InstrumentDesign.Spacing.section) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                HStack(spacing: 7) {
                    SectionHeading(
                        "相关位置",
                        subtitle: "当前打开的位置，以及最近 5 分钟观察到修改的位置"
                    )
                    Button { isFileActivityHelpPresented.toggle() } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(AppIconButtonStyle(size: 26, isFramed: false))
                    .onHover { if $0 { isFileActivityHelpPresented = true } }
                    .popover(isPresented: $isFileActivityHelpPresented, arrowEdge: .top) {
                        FileActivityExplanationPopover()
                    }
                    .accessibilityLabel(L10n.text("了解文件活动"))
                }
                Spacer(minLength: 10)
                status
                if let snapshot {
                    Text(L10n.date(snapshot.capturedAt, date: .omitted, time: .standard))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Button { isObservationPaused.toggle() } label: {
                    Image(systemName: isObservationPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(AppIconButtonStyle(size: 30))
                .help(L10n.text(isObservationPaused ? "返回实时" : "暂停实时跟随"))
                .accessibilityLabel(L10n.text(isObservationPaused ? "返回实时" : "暂停实时跟随"))
            }

            HStack(spacing: 0) {
                FileActivityInstrument(
                    title: "位置",
                    value: L10n.number(rows.count),
                    symbol: "folder",
                    color: InstrumentDesign.ColorRole.cpu
                ) {
                    MicroHistogram(
                        values: rowSummary.fileCountHistogram,
                        accent: InstrumentDesign.ColorRole.cpu
                    )
                }
                .frame(maxWidth: .infinity)
                Divider().frame(height: 46).padding(.horizontal, 12)
                FileActivityInstrument(
                    title: "可写",
                    value: L10n.number(rowSummary.writableCount),
                    symbol: "pencil.line",
                    color: InstrumentDesign.ColorRole.write
                ) {
                    SegmentedEnergyMeter(
                        fraction: rows.isEmpty
                            ? 0
                            : Double(rowSummary.writableCount) / Double(rows.count),
                        color: InstrumentDesign.ColorRole.write,
                        segments: 12
                    )
                }
                .frame(maxWidth: .infinity)
                Divider().frame(height: 46).padding(.horizontal, 12)
                FileActivityInstrument(
                    title: "打开文件",
                    value: L10n.number(rowSummary.openFileCount),
                    symbol: "doc.on.doc",
                    color: InstrumentDesign.ColorRole.read
                ) {
                    MicroHistogram(
                        values: rowSummary.fileCountHistogram,
                        accent: InstrumentDesign.ColorRole.read
                    )
                }
                .frame(maxWidth: .infinity)
                Divider().frame(height: 46).padding(.horizontal, 12)
                FileActivityInstrument(
                    title: "最近 5 分钟修改",
                    value: L10n.number(rowSummary.changedCount),
                    symbol: "clock.arrow.circlepath",
                    color: InstrumentDesign.ColorRole.memory
                ) {
                    SegmentedEnergyMeter(
                        fraction: rows.isEmpty
                            ? 0
                            : Double(rowSummary.changedCount) / Double(rows.count),
                        color: InstrumentDesign.ColorRole.memory,
                        segments: 12
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .glassSurface(padding: 0)

            HStack(spacing: 10) {
                observationSummary
                Spacer(minLength: 8)
                if traceStore.selection != nil { traceSessionShortcut }
            }
        }
        .padding(.horizontal, InstrumentDesign.Spacing.page)
        .padding(.vertical, InstrumentDesign.Spacing.section)
    }

    private var traceSessionShortcut: some View {
        Button {
            tracedPath = traceStore.selection?.url.path
        } label: {
            HStack(spacing: 10) {
                Image(systemName: traceStore.isRunning ? "scope" : "clock.arrow.circlepath")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(traceStore.isRunning ? Color.green : Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(
                        (traceStore.isRunning ? Color.green : Color.accentColor).opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text(traceStore.isRunning ? "目录追踪正在运行" : "目录读写追踪"))
                        .font(.callout.weight(.semibold))
                    Text(traceStore.selection?.privatePath ?? "")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Text(L10n.text("查看追踪"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.accentColor.opacity(0.045))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.accentColor).frame(width: 3)
        }
        .accessibilityHint(L10n.text("打开当前目录的读写追踪详情"))
    }

    @ViewBuilder
    private var observationSummary: some View {
        if fileChangesUnavailable {
            Label(L10n.text("当前卷无法观察最近变化"), systemImage: "eye.slash")
        } else if let observedSince = fileChangesObservedSince {
            Label(
                L10n.format(
                    "自 %@ 开始观察",
                    L10n.date(observedSince, date: .omitted, time: .standard)
                ),
                systemImage: "eye"
            )
        } else {
            Label(L10n.text("正在建立变化基线"), systemImage: "clock")
        }
    }

    @ViewBuilder
    private var fileActivityContent: some View {
        if snapshot == nil {
            fileWorkspaceSkeleton
        } else if rows.isEmpty {
            emptyOrUnavailable
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            fileWorkspace
        }
    }

    private var volumeTopology: String {
        volumes
            .map {
                "\($0.id):\($0.name):\($0.mountPath):\($0.isLocal):\($0.isWritable):\($0.hasStableIdentity)"
            }
            .sorted()
            .joined(separator: ",")
    }

    @ViewBuilder
    private var status: some View {
        if let snapshot {
            switch snapshot.state {
            case .complete:
                EvidenceLabel(text: "本次扫描完整", symbol: "checkmark.circle")
            case .partial:
                Label(partialStatus(snapshot), systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .processEnded:
                EvidenceLabel(text: "应用已经结束，保留最后一次结果", symbol: "clock.badge.xmark")
            case .unavailable:
                EvidenceLabel(
                    text: snapshot.permissionLimited
                        ? "未能读取任何位置；部分路径受保护或进程不可见"
                        : "当前无法读取文件位置",
                    symbol: "eye.slash"
                )
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L10n.text("正在扫描当前打开的位置…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var fileWorkspace: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 720 {
                HStack(spacing: 0) {
                    locationBrowser
                        .frame(width: fileBrowserWidth(for: geometry.size.width))
                    Divider()
                    locationDetail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    locationBrowser
                        .frame(height: min(300, max(230, geometry.size.height * 0.42)))
                    Divider()
                    locationDetail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .glassSurface(padding: 0)
    }

    private func fileBrowserWidth(for availableWidth: CGFloat) -> CGFloat {
        min(390, max(320, availableWidth * 0.36))
    }

    private var locationBrowser: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(L10n.text("筛选位置"), text: $searchText)
                        .textFieldStyle(.plain)
                    if isUpdatingVisibleRows {
                        ProgressView()
                            .controlSize(.mini)
                            .help(L10n.text("正在更新筛选结果"))
                            .accessibilityLabel(L10n.text("正在更新筛选结果"))
                    }
                    Menu {
                        Picker(L10n.text("排序"), selection: $sort) {
                            ForEach(FileActivitySort.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .frame(width: 26, height: 26)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(L10n.text("排序"))
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
                .overlay {
                    RoundedRectangle(cornerRadius: InstrumentDesign.Radius.control)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: InstrumentDesign.Stroke.hairline)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))

                FileActivityFilterControl(selection: $filter)
            }
            .padding(12)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleRows) { row in
                        Button {
                            selectedPath = row.id
                            tracePreparationError = nil
                        } label: {
                            FileLocationRow(
                                row: row,
                                path: displayPath(row.path),
                                access: row.isCurrentlyOpen
                                    ? accessDescription(row.modes)
                                    : L10n.text("当前未打开"),
                                isWritable: isWritable(row),
                                isSelected: selectedPath == row.id,
                                isTraceRunning: isActiveTraceTarget(row) && traceStore.isRunning
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            fileLocationActions(row)
                        }
                        Divider().padding(.leading, 48)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(InstrumentDesign.Palette.sidebarTint.opacity(0.42))
    }

    @ViewBuilder
    private var locationDetail: some View {
        if let selectedRow {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: isWritable(selectedRow) ? "folder.badge.gearshape" : "folder.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(isWritable(selectedRow) ? Color.orange : Color.blue)
                            .frame(width: 48, height: 48)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: InstrumentDesign.Radius.icon))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selectedRow.displayName)
                                .font(.system(size: 20, weight: .semibold))
                                .textSelection(.enabled)
                            Text(displayPath(selectedRow.path))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 12)
                        Button {
                            openTrace(selectedRow)
                        } label: {
                            if pendingTracePath == selectedRow.path {
                                HStack(spacing: 7) {
                                    ProgressView().controlSize(.small)
                                    Text(L10n.text("正在开始"))
                                }
                            } else {
                                Label(
                                    L10n.text(isActiveTraceTarget(selectedRow) ? "查看追踪" : "追踪此目录"),
                                    systemImage: "scope"
                                )
                            }
                        }
                        .buttonStyle(AppActionButtonStyle(kind: .primary, size: .compact))
                        .disabled(
                            !canOpenTrace(selectedRow)
                                || pendingTracePath == selectedRow.path
                        )
                        .help(L10n.text(
                            canOpenTrace(selectedRow)
                                ? "查看此目录内具体的请求读写、活跃文件和访问应用"
                                : "请先停止当前目录的追踪"
                        ))
                        Button {
                            copyPath(selectedRow.path)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(AppIconButtonStyle(size: 30))
                        .help(L10n.text("复制路径"))
                        Button {
                            revealInFinder(selectedRow.path)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(AppIconButtonStyle(size: 30))
                        .help(L10n.text("在 Finder 中显示"))
                    }

                    if let tracePreparationError {
                        Label(tracePreparationError, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityLabel(tracePreparationError)
                    }

                    Divider()

                    Grid(alignment: .leading, horizontalSpacing: 34, verticalSpacing: 12) {
                        locationMetadataRow(
                            selectedRow.isCurrentlyOpen ? "打开方式" : "状态",
                            selectedRow.isCurrentlyOpen
                                ? accessDescription(selectedRow.modes)
                                : L10n.text("当前未打开")
                        )
                        locationMetadataRow("打开文件", L10n.number(selectedRow.fileCount))
                        locationMetadataRow("所在卷", selectedRow.volumeName)
                        if let tracked = selectedTrackedLocation {
                            locationMetadataRow(
                                "首次观察",
                                L10n.date(tracked.firstObservedAt, date: .omitted, time: .standard)
                            )
                            locationMetadataRow(
                                "最后活动",
                                L10n.date(
                                    selectedRow.lastChangedAt ?? tracked.lastSeenOpenAt,
                                    date: .omitted,
                                    time: .standard
                                )
                            )
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.text("修改记录"))
                            .font(.headline)
                        FileChangeEvidenceBand(
                            lastChangedAt: selectedRow.lastChangedAt,
                            observationStatus: selectedRow.changeObservationStatus,
                            hasGap: fileChangesHaveGap,
                            hasBaseline: fileChangesObservedSince != nil
                        )
                    }
                }
                .padding(22)
                .frame(maxWidth: 760, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView(
                L10n.text("选择一个位置"),
                systemImage: "folder"
            )
        }
    }

    private var fileWorkspaceSkeleton: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 5)
                    .frame(height: 32)
                    .padding(12)
                Divider()
                ForEach(0..<5, id: \.self) { _ in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 6).frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 7) {
                            RoundedRectangle(cornerRadius: 3).frame(width: 150, height: 11)
                            RoundedRectangle(cornerRadius: 3).frame(width: 220, height: 9)
                        }
                        Spacer()
                    }
                    .padding(12)
                    Divider().padding(.leading, 48)
                }
                Spacer()
            }
            .frame(width: 350)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 7).frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 3).frame(width: 180, height: 13)
                        RoundedRectangle(cornerRadius: 3).frame(width: 300, height: 10)
                    }
                }
                Divider()
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 3).frame(width: 280, height: 12)
                }
                Spacer()
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(Color.secondary.opacity(0.09))
        .accessibilityHidden(true)
    }

    @MainActor
    private func scheduleVisibleRowsUpdate(
        debounce: Bool = false,
        showsProgress: Bool = false
    ) {
        visibleRowsTask?.cancel()
        isUpdatingVisibleRows = showsProgress || isUpdatingVisibleRows || visibleRows.isEmpty
        let sourceRows = rows
        let requestedFilter = filter
        let requestedSort = sort
        let requestedSearch = searchText

        visibleRowsTask = Task { @MainActor in
            await Task.yield()
            if debounce {
                do {
                    try await Task.sleep(for: .milliseconds(90))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            let nextRows = await Task.detached(priority: .userInitiated) {
                Self.makeVisibleRows(
                    sourceRows,
                    filter: requestedFilter,
                    sort: requestedSort,
                    searchText: requestedSearch
                )
            }.value
            guard !Task.isCancelled else { return }

            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                visibleRows = nextRows
                if let selectedPath, nextRows.contains(where: { $0.id == selectedPath }) {
                    self.selectedPath = selectedPath
                } else {
                    selectedPath = nextRows.first?.id
                }
                isUpdatingVisibleRows = false
            }
        }
    }

    nonisolated private static func makeVisibleRows(
        _ rows: [FileAccessDirectory],
        filter: FileActivityFilter,
        sort: FileActivitySort,
        searchText: String
    ) -> [FileAccessDirectory] {
        let searched = rows.filter { row in
            searchText.isEmpty
                || row.displayName.localizedCaseInsensitiveContains(searchText)
                || row.path.localizedCaseInsensitiveContains(searchText)
                || row.volumeName.localizedCaseInsensitiveContains(searchText)
        }
        return searched.filter { row in
            switch filter {
            case .all: true
            case .writable:
                row.modes.contains(.writeOnly) || row.modes.contains(.readWrite)
            case .changed: row.lastChangedAt != nil
            }
        }
        .sorted { lhs, rhs in
            switch sort {
            case .name:
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            case .fileCount:
                return lhs.fileCount == rhs.fileCount
                    ? lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                    : lhs.fileCount > rhs.fileCount
            case .recentChange:
                if lhs.lastChangedAt == rhs.lastChangedAt {
                    return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                }
                return (lhs.lastChangedAt ?? .distantPast) > (rhs.lastChangedAt ?? .distantPast)
            }
        }
    }

    private var selectedRow: FileAccessDirectory? {
        guard let selectedPath else { return visibleRows.first }
        return visibleRows.first { $0.id == selectedPath }
    }

    private var selectedTrackedLocation: TrackedFileLocation? {
        guard let selectedRow else { return nil }
        return trackedLocations[selectedRow.path]
    }

    private func isWritable(_ row: FileAccessDirectory) -> Bool {
        row.modes.contains(.writeOnly) || row.modes.contains(.readWrite)
    }

    private func locationMetadataRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(L10n.text(title))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.system(.body, design: .monospaced, weight: .medium))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func fileLocationActions(_ row: FileAccessDirectory) -> some View {
        Button {
            openTrace(row)
        } label: {
            Label(L10n.text("追踪此目录"), systemImage: "scope")
        }
        .disabled(!canOpenTrace(row))
        Divider()
        Button {
            revealInFinder(row.path)
        } label: {
            Label(L10n.text("在 Finder 中显示"), systemImage: "folder")
        }
        Button {
            copyPath(row.path)
        } label: {
            Label(L10n.text("复制路径"), systemImage: "doc.on.doc")
        }
    }

    private func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func canOpenTrace(_ row: FileAccessDirectory) -> Bool {
        !traceStore.isRunning || isActiveTraceTarget(row)
    }

    private func isActiveTraceTarget(_ row: FileAccessDirectory) -> Bool {
        traceStore.selection?.url.standardizedFileURL.path
            == URL(fileURLWithPath: row.path).standardizedFileURL.path
    }

    private func openTrace(_ row: FileAccessDirectory) {
        selectedPath = row.id
        tracePreparationError = nil
        guard canOpenTrace(row) else {
            return
        }
        let url = URL(fileURLWithPath: row.path, isDirectory: true).standardizedFileURL
        let isExistingTarget = isActiveTraceTarget(row)
        if isExistingTarget {
            pendingTracePath = nil
            tracedPath = url.path
            return
        }

        tracePreparationTask?.cancel()
        pendingTracePath = row.path
        tracePreparationTask = Task { @MainActor in
            await Task.yield()
            do {
                let preparedSelection = try await Task.detached(priority: .userInitiated) {
                    try FileAccessTraceSelection.make(url: url)
                }.value
                guard !Task.isCancelled, pendingTracePath == row.path else { return }
                traceStore.select(preparedSelection)
                guard traceStore.selection?.url.standardizedFileURL.path == url.path else {
                    pendingTracePath = nil
                    return
                }
                tracedPath = url.path
                pendingTracePath = nil
            } catch is CancellationError {
                if pendingTracePath == row.path { pendingTracePath = nil }
            } catch {
                guard !Task.isCancelled, pendingTracePath == row.path else { return }
                traceStore.reportSelectionPreparationFailure()
                tracePreparationError = L10n.text("无法读取所选位置的信息")
                pendingTracePath = nil
            }
        }
    }

    @ViewBuilder
    private var emptyOrUnavailable: some View {
        switch snapshot?.state {
        case .complete:
            ContentUnavailableView(
                L10n.text("当前没有观察到普通文件"),
                systemImage: "doc",
                description: Text(L10n.text("应用可能暂时空闲、使用内存映射，或尚未打开文件。"))
            )
        case .processEnded:
            ContentUnavailableView(L10n.text("应用已经结束"), systemImage: "clock.badge.xmark")
        default:
            ContentUnavailableView(
                L10n.text("当前无法读取文件位置"),
                systemImage: "eye.slash",
                description: Text(L10n.text(
                    snapshot?.permissionLimited == true
                        ? "未能读取任何位置；部分路径受保护或进程不可见"
                        : "基础 CPU、磁盘与网络监控仍然可用。"
                ))
            )
        }
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            if isObservationPaused {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                continue
            }
            let sessions = monitoredSessions
            let next: OpenFileSnapshot
            if sessions.isEmpty {
                let previous = snapshot
                next = OpenFileSnapshot(
                    capturedAt: Date(),
                    records: [],
                    state: .processEnded,
                    observedVnodeCount: 0,
                    unreadableCount: 0,
                    sampledProcessCount: 0,
                    requestedProcessCount: previous?.requestedProcessCount ?? 0,
                    permissionLimited: false,
                    budgetLimited: false
                )
            } else {
                next = await OpenFileSampler.shared.sample(sessions: sessions)
            }

            let currentVolumes = monitoredVolumes
            let currentRows = await Task.detached(priority: .utility) {
                Self.buildRows(snapshot: next, volumes: currentVolumes)
            }.value
            let previousTrackedLocations = trackedLocations
            let trackingCandidates = await Task.detached(priority: .utility) {
                Self.makeTrackingCandidates(
                    currentRows: currentRows,
                    previousTrackedLocations: previousTrackedLocations,
                    capturedAt: next.capturedAt
                )
            }.value
            let changes = await FileChangeWatcher.shared.recentChanges(
                for: Array(trackingCandidates.keys)
            )
            let projection = await Task.detached(priority: .utility) {
                Self.makeRefreshProjection(
                    currentRows: currentRows,
                    trackingCandidates: trackingCandidates,
                    changes: changes,
                    capturedAt: next.capturedAt,
                    volumes: currentVolumes
                )
            }.value
            guard !Task.isCancelled else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if next.state == .processEnded, let previous = snapshot {
                    snapshot = OpenFileSnapshot(
                        capturedAt: previous.capturedAt,
                        records: previous.records,
                        state: .processEnded,
                        observedVnodeCount: previous.observedVnodeCount,
                        unreadableCount: previous.unreadableCount,
                        sampledProcessCount: 0,
                        requestedProcessCount: next.requestedProcessCount,
                        permissionLimited: next.permissionLimited,
                        budgetLimited: next.budgetLimited
                    )
                } else {
                    snapshot = next
                }
                trackedLocations = projection.trackedLocations
                rows = projection.rows
                rowSummary = projection.summary
                fileChangesHaveGap = changes.hasCoverageGap
                fileChangesObservedSince = changes.observedSince
                fileChangesUnavailable = projection.changesUnavailable
            }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
        }
    }

    nonisolated private static func makeTrackingCandidates(
        currentRows: [FileAccessDirectory],
        previousTrackedLocations: [String: TrackedFileLocation],
        capturedAt: Date
    ) -> [String: TrackedFileLocation] {
        let currentPaths = Set(currentRows.map(\.path))
        let trackingCutoff = capturedAt.addingTimeInterval(-FileChangeWatcher.recentChangeWindow)
        var candidates = previousTrackedLocations.filter { path, tracked in
            let retainedChange = RecentFileChangeRetention.retainedTimestamp(
                previous: tracked.row.lastChangedAt,
                observed: nil,
                now: capturedAt
            )
            return currentPaths.contains(path)
                || tracked.lastSeenOpenAt >= trackingCutoff
                || retainedChange != nil
        }
        for row in currentRows {
            let existing = candidates[row.path]
            candidates[row.path] = TrackedFileLocation(
                row: existing?.row ?? row,
                firstObservedAt: existing?.firstObservedAt ?? capturedAt,
                lastSeenOpenAt: capturedAt
            )
        }
        return candidates
    }

    nonisolated private static func makeRefreshProjection(
        currentRows: [FileAccessDirectory],
        trackingCandidates: [String: TrackedFileLocation],
        changes: FileChangeLookup,
        capturedAt: Date,
        volumes: [VolumeInfo]
    ) -> FileActivityRefreshProjection {
        let currentRowsByPath = Dictionary(uniqueKeysWithValues: currentRows.map { ($0.path, $0) })
        var updatedTrackedLocations = trackingCandidates
        let nextRows = trackingCandidates.values.compactMap { tracked -> FileAccessDirectory? in
            let currentRow = currentRowsByPath[tracked.row.path]
            let lastChangedAt = RecentFileChangeRetention.retainedTimestamp(
                previous: tracked.row.lastChangedAt,
                observed: changes.latestByPath[tracked.row.path],
                now: capturedAt
            )
            guard currentRow != nil || lastChangedAt != nil else { return nil }
            let row = rebindingVolume(currentRow ?? tracked.row, volumes: volumes)
            return FileAccessDirectory(
                path: row.path,
                displayName: row.displayName,
                volumeName: row.volumeName,
                modes: row.modes,
                fileCount: currentRow?.fileCount ?? 0,
                lastChangedAt: lastChangedAt,
                changeObservationStatus: changes.statusByPath[row.path] ?? .unavailable,
                isCurrentlyOpen: currentRow != nil
            )
        }
        for row in nextRows {
            guard let tracked = updatedTrackedLocations[row.path] else { continue }
            updatedTrackedLocations[row.path] = TrackedFileLocation(
                row: row,
                firstObservedAt: tracked.firstObservedAt,
                lastSeenOpenAt: tracked.lastSeenOpenAt
            )
        }
        return FileActivityRefreshProjection(
            rows: nextRows,
            trackedLocations: updatedTrackedLocations,
            changesUnavailable: !nextRows.isEmpty && nextRows.allSatisfy {
                $0.changeObservationStatus == .unavailable
            },
            summary: makeRowSummary(nextRows)
        )
    }

    nonisolated private static func makeRowSummary(
        _ rows: [FileAccessDirectory]
    ) -> FileActivityRowSummary {
        var writableCount = 0
        var changedCount = 0
        var openFileCount = 0
        var fileCountHistogram: [Double] = []
        fileCountHistogram.reserveCapacity(rows.count)
        for row in rows {
            if row.modes.contains(.writeOnly) || row.modes.contains(.readWrite) {
                writableCount += 1
            }
            if row.lastChangedAt != nil { changedCount += 1 }
            openFileCount += row.fileCount
            fileCountHistogram.append(Double(row.fileCount))
        }
        return FileActivityRowSummary(
            writableCount: writableCount,
            changedCount: changedCount,
            openFileCount: openFileCount,
            fileCountHistogram: fileCountHistogram
        )
    }

    nonisolated private static func buildRows(
        snapshot: OpenFileSnapshot,
        volumes: [VolumeInfo]
    ) -> [FileAccessDirectory] {
        struct Accumulator {
            var modes: Set<OpenFileAccessMode> = []
            var identities: Set<String> = []
        }
        var grouped: [String: Accumulator] = [:]
        for record in snapshot.records where record.accessMode != .eventOnly {
            let directory = record.isDirectory
                ? record.path
                : URL(fileURLWithPath: record.path).deletingLastPathComponent().path
            var value = grouped[directory, default: Accumulator()]
            value.modes.insert(record.accessMode)
            value.identities.insert("\(record.device):\(record.inode)")
            grouped[directory] = value
        }
        return grouped.map { path, value in
            let volume = VolumePathResolver.bestMatch(for: path, in: volumes)
            return FileAccessDirectory(
                path: path,
                displayName: URL(fileURLWithPath: path).lastPathComponent.isEmpty
                    ? (volume?.name ?? path)
                    : URL(fileURLWithPath: path).lastPathComponent,
                volumeName: volume?.name ?? L10n.text("未知卷"),
                modes: value.modes,
                fileCount: value.identities.count,
                lastChangedAt: nil,
                changeObservationStatus: .unavailable,
                isCurrentlyOpen: true
            )
        }
        .sorted {
            if $0.fileCount != $1.fileCount { return $0.fileCount > $1.fileCount }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private func rebindRows(to volumes: [VolumeInfo]) {
        guard !volumes.isEmpty else { return }
        rows = rows.map { Self.rebindingVolume($0, volumes: volumes) }
        trackedLocations = trackedLocations.mapValues { tracked in
            TrackedFileLocation(
                row: Self.rebindingVolume(tracked.row, volumes: volumes),
                firstObservedAt: tracked.firstObservedAt,
                lastSeenOpenAt: tracked.lastSeenOpenAt
            )
        }
    }

    nonisolated private static func rebindingVolume(
        _ row: FileAccessDirectory,
        volumes: [VolumeInfo]
    ) -> FileAccessDirectory {
        guard let volume = VolumePathResolver.bestMatch(for: row.path, in: volumes) else {
            return row
        }
        return FileAccessDirectory(
            path: row.path,
            displayName: row.displayName,
            volumeName: volume.name,
            modes: row.modes,
            fileCount: row.fileCount,
            lastChangedAt: row.lastChangedAt,
            changeObservationStatus: row.changeObservationStatus,
            isCurrentlyOpen: row.isCurrentlyOpen
        )
    }

    private func partialStatus(_ snapshot: OpenFileSnapshot) -> String {
        if snapshot.permissionLimited {
            return rows.isEmpty
                ? L10n.text("未能读取任何位置；部分路径受保护或进程不可见")
                : L10n.text("已显示可读取的位置；部分受保护路径不可见")
        }
        if snapshot.budgetLimited {
            return L10n.text("位置较多，当前只显示部分结果")
        }
        return L10n.text("部分文件在扫描时已经关闭")
    }

    private func accessDescription(_ modes: Set<OpenFileAccessMode>) -> String {
        if modes.contains(.readWrite) { return L10n.text("读写") }
        if modes.contains(.writeOnly) && modes.contains(.readOnly) {
            return L10n.text("只读与可写")
        }
        if modes.contains(.writeOnly) { return L10n.text("可写") }
        if modes.contains(.readOnly) { return L10n.text("只读") }
        return L10n.text("未知")
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

private struct FileActivityInstrument<Visualization: View>: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color
    @ViewBuilder let visualization: () -> Visualization

    init(
        title: String,
        value: String,
        symbol: String,
        color: Color,
        @ViewBuilder visualization: @escaping () -> Visualization
    ) {
        self.title = title
        self.value = value
        self.symbol = symbol
        self.color = color
        self.visualization = visualization
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text(L10n.text(title))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Spacer(minLength: 4)
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(color.opacity(0.88))
                    .accessibilityHidden(true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(value)
                    .font(.system(size: 28, weight: .light, design: .default))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                visualization()
                    .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 34, alignment: .center)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text(title))
        .accessibilityValue(value)
    }
}

private struct FileActivityMetric: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(.body, design: .monospaced, weight: .semibold))
                    .monospacedDigit()
                Text(L10n.text(title))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FileActivityFilterControl: View {
    @Binding var selection: FileActivityFilter

    var body: some View {
        HStack(spacing: 2) {
            ForEach(FileActivityFilter.allCases) { option in
                Button {
                    selection = option
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: selection == option ? .medium : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .frame(maxWidth: .infinity, minHeight: 29)
                        .foregroundStyle(selection == option ? .primary : .secondary)
                        .background {
                            RoundedRectangle(cornerRadius: InstrumentDesign.Radius.control)
                                .fill(selection == option ? Color.primary.opacity(0.13) : .clear)
                                .overlay {
                                    if selection == option {
                                        RoundedRectangle(cornerRadius: InstrumentDesign.Radius.control)
                                            .strokeBorder(Color.white.opacity(0.11), lineWidth: 0.5)
                                    }
                                }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: InstrumentDesign.Radius.control)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.48))
                .overlay {
                    RoundedRectangle(cornerRadius: InstrumentDesign.Radius.control)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: InstrumentDesign.Stroke.hairline)
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("位置筛选"))
    }
}

private struct FileActivityExplanationPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.text("文件活动如何统计"), systemImage: "questionmark.circle.fill")
                .font(.headline)

            explanationRow(
                "应用当前打开的位置会实时更新。",
                symbol: "folder"
            )
            explanationRow(
                "观察到修改后，即使文件已经关闭，该位置仍会保留 5 分钟。",
                symbol: "clock.arrow.circlepath"
            )
            explanationRow(
                "修改来自 macOS 文件系统事件，无法确认一定由此应用造成。",
                symbol: "info.circle"
            )
        }
        .padding(14)
        .frame(width: 330, alignment: .leading)
    }

    private func explanationRow(_ text: String, symbol: String) -> some View {
        Label {
            Text(L10n.text(text))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

private struct FileLocationRow: View {
    let row: FileAccessDirectory
    let path: String
    let access: String
    let isWritable: Bool
    let isSelected: Bool
    let isTraceRunning: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.isCurrentlyOpen
                ? (isWritable ? "folder.badge.gearshape" : "folder")
                : "clock.arrow.circlepath")
                .font(.body.weight(.medium))
                .foregroundStyle(
                    row.isCurrentlyOpen
                        ? (isWritable ? Color.orange : Color.blue)
                        : Color.purple
                )
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(access)
                    Text("·")
                    Text(L10n.format("%d 个文件", row.fileCount))
                    Text("·")
                    Text(row.volumeName)
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isTraceRunning {
                Label(L10n.text("追踪中"), systemImage: "scope")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.green)
                    .lineLimit(1)
            } else if let lastChangedAt = row.lastChangedAt {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(L10n.format(
                        "修改于 %@",
                        L10n.date(lastChangedAt, date: .omitted, time: .standard)
                    ))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.purple)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 72)
        .background(isSelected ? Color.accentColor.opacity(0.11) : .clear)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(Color.accentColor).frame(width: 3)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct FileChangeEvidenceBand: View {
    let lastChangedAt: Date?
    let observationStatus: FileChangeObservationStatus
    let hasGap: Bool
    let hasBaseline: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(color.opacity(0.055))
        .overlay(alignment: .leading) {
            Rectangle().fill(color).frame(width: 3)
        }
    }

    private var title: String {
        if lastChangedAt != nil { return L10n.text("观察到修改") }
        if observationStatus == .unavailable { return L10n.text("无法观察此位置") }
        if hasGap || hasBaseline { return L10n.text("没有观察到修改") }
        return L10n.text("正在开始观察")
    }

    private var detail: String {
        if let lastChangedAt {
            return L10n.format(
                "最近一次 %@，但无法确认是否由此应用造成",
                L10n.date(lastChangedAt, date: .omitted, time: .standard)
            )
        }
        if observationStatus == .unavailable {
            return L10n.text("系统暂时无法获取这个位置的修改记录")
        }
        if hasGap {
            return L10n.text("已观察的时段内没有修改记录；部分时段没有数据")
        }
        if hasBaseline {
            return L10n.text("观察期间没有发现这个位置被修改")
        }
        return L10n.text("稍后会显示这个位置是否发生修改")
    }

    private var symbol: String {
        if lastChangedAt != nil { return "clock.arrow.circlepath" }
        if observationStatus == .unavailable { return "eye.slash" }
        if hasGap { return "exclamationmark.triangle" }
        if hasBaseline { return "checkmark" }
        return "clock"
    }

    private var color: Color {
        if lastChangedAt != nil { return .purple }
        if hasGap { return .orange }
        return .secondary
    }
}

struct ProcessDetailWindowRoot: View {
    let store: MonitorStore
    let coordinator: ProcessDetailWindowCoordinator
    let presentation: ProcessDetailPresentation
    let traceActivityRegistry: TraceActivityRegistry

    var body: some View {
        ProcessDetailSheet(
            store: store,
            presentation: presentation,
            traceActivityRegistry: traceActivityRegistry
        )
        .frame(minWidth: 780, minHeight: 560)
        .navigationTitle(presentation.process.localizedDisplayName)
        .background {
            ProcessDetailWindowRegistration(
                processID: presentation.id,
                coordinator: coordinator
            )
        }
    }
}

private struct ProcessDetailWindowRegistration: NSViewRepresentable {
    let processID: ProcessActivity.ID
    let coordinator: ProcessDetailWindowCoordinator

    func makeNSView(context: Context) -> RegistrationView {
        RegistrationView(processID: processID, coordinator: coordinator)
    }

    func updateNSView(_ nsView: RegistrationView, context: Context) {
        nsView.processID = processID
        nsView.coordinator = coordinator
        nsView.registerWindow()
    }

    final class RegistrationView: NSView {
        var processID: ProcessActivity.ID
        weak var coordinator: ProcessDetailWindowCoordinator?

        init(
            processID: ProcessActivity.ID,
            coordinator: ProcessDetailWindowCoordinator
        ) {
            self.processID = processID
            self.coordinator = coordinator
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            registerWindow()
        }

        func registerWindow() {
            guard let window else { return }
            coordinator?.register(window, for: processID)
        }
    }
}
