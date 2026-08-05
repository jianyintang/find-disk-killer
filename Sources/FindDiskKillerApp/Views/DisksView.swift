import AppKit
import FindDiskKillerCore
import SwiftUI

struct DisksView: View {
    let store: MonitorStore
    @State private var showHardwareDetails = true
    @State private var selectedMode: DiskPageMode = .activity
    @State private var selectedHealthDisk: String?
    @State private var volumeTraceStore = VolumeAccessTraceStore()

    var body: some View {
        VStack(spacing: 0) {
            InstrumentPageHeader("磁盘") {
                HStack(spacing: InstrumentDesign.Spacing.related) {
                    GlassSegmentedControl(
                        "磁盘视图",
                        selection: $selectedMode
                    ) {
                        ForEach(DiskPageMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .frame(width: 260)

                    if selectedMode == .health {
                        Button(action: refreshHealth) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(AppIconButtonStyle(size: 30))
                        .help(L10n.text("重新读取健康数据"))
                        .accessibilityLabel(L10n.text("重新读取健康数据"))
                        .disabled(healthRefreshInProgress)
                    }
                }
            }

            switch selectedMode {
            case .activity:
                activityContent
            case .health:
                healthContent
            }
        }
        .task(id: healthDevices) {
            if selectedHealthDisk == nil {
                selectedHealthDisk = healthDeviceNames.first
            }
            await store.diskHealth.refresh(devices: healthDevices)
        }
        .task(id: processSessionTopology) {
            volumeTraceStore.setProcessSessions(allProcessSessions)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            volumeTraceStore.refreshPermissionStatus()
        }
        .background(InstrumentCanvas())
    }

    private var activityContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    MetricValue(
                        title: "读取 · 最近 5 秒",
                        value: store.isDiskAvailable
                            ? ByteRateFormatter.rate(store.currentReadRate)
                            : "采样缺口",
                        symbol: "eye",
                        color: InstrumentDesign.ColorRole.diskRead
                    )
                    Divider().frame(height: 38)
                    MetricValue(
                        title: "写入 · 最近 5 秒",
                        value: store.isDiskAvailable
                            ? ByteRateFormatter.rate(store.currentWriteRate)
                            : "采样缺口",
                        symbol: "pencil.line",
                        color: InstrumentDesign.ColorRole.diskWrite
                    )
                    Divider().frame(height: 38)
                    MetricValue(
                        title: "已挂载卷",
                        value: L10n.number(store.volumes.count),
                        symbol: "externaldrive.connected.to.line.below",
                        color: .blue
                    )
                }
                .glassSurface(padding: 16)

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeading("物理设备总吞吐", subtitle: "虚拟磁盘不计入总量")
                    MonitorChart(
                        points: chartPoints,
                        height: 220,
                        warningThreshold: MonitorStore.elevatedDeviceWriteRate,
                        windowDuration: store.selectedRange.seconds
                    )
                }
                .glassSurface(padding: 16)

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeading("已挂载卷", subtitle: "卷名直接对应底层设备的实时吞吐")
                    ForEach(store.volumes) { volume in
                        VolumeRow(
                            volume: volume,
                            disks: physicalDisks(for: volume),
                            sharesDevice: sharesPhysicalDevice(volume),
                            traceIsRunning: volumeTraceStore.isRunning,
                            onTraceAccessSource: {
                                volumeTraceStore.select(volume, startImmediately: true)
                            }
                        )
                        Divider()
                    }
                }
                .glassSurface(padding: 16)

                if volumeTraceStore.selection != nil {
                    VolumeAccessTracePanel(store: volumeTraceStore)
                }

                DisclosureGroup(isExpanded: $showHardwareDetails) {
                    VStack(spacing: 0) {
                        ForEach(sortedDisks) { disk in
                            DiskRow(disk: disk, volumeNames: volumeNames(for: disk))
                            Divider()
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text(L10n.text("硬件诊断"))
                        .font(.headline)
                }
                .help(L10n.text("显示底层 IOKit 设备节点"))
                .glassSurface(padding: 16)
            }
            .padding(InstrumentDesign.Spacing.page)
        }
    }

    @ViewBuilder
    private var healthContent: some View {
        if physicalHealthDisks.isEmpty {
            if let selectedHealthDisk,
               let snapshot = store.diskHealth.state(for: selectedHealthDisk).snapshot {
                DiskHealthDetail(
                    diskName: snapshot.model,
                    bsdName: selectedHealthDisk,
                    volumeNames: [],
                    state: store.diskHealth.state(for: selectedHealthDisk)
                )
            } else {
                ContentUnavailableView(
                    L10n.text("没有可读取的物理磁盘"),
                    systemImage: "internaldrive",
                    description: Text(L10n.text("实时吞吐与已挂载卷仍然可以正常使用。"))
                )
            }
        } else {
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Text(L10n.text("物理设备"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(L10n.number(physicalHealthDisks.count))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    Divider()

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(physicalHealthDisks) { disk in
                                Button {
                                    selectedHealthDisk = disk.bsdName
                                } label: {
                                    DiskHealthDeviceRow(
                                        disk: disk,
                                        volumeNames: volumeNames(for: disk),
                                        state: store.diskHealth.state(for: disk.bsdName),
                                        isSelected: selectedHealthDisk == disk.bsdName
                                    )
                                }
                                .buttonStyle(.plain)
                                Divider().padding(.leading, 52)
                            }
                        }
                    }
                }
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)
                .glassSurface(padding: 0)

                if let selectedHealthDisk,
                   let disk = physicalHealthDisks.first(where: {
                       $0.bsdName == selectedHealthDisk
                   }) {
                    DiskHealthDetail(
                        diskName: disk.name,
                        bsdName: disk.bsdName,
                        volumeNames: volumeNames(for: disk),
                        state: store.diskHealth.state(for: selectedHealthDisk)
                    )
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                    .glassSurface(padding: 0)
                } else if let selectedHealthDisk,
                          let snapshot = store.diskHealth.state(for: selectedHealthDisk).snapshot {
                    DiskHealthDetail(
                        diskName: snapshot.model,
                        bsdName: selectedHealthDisk,
                        volumeNames: [],
                        state: store.diskHealth.state(for: selectedHealthDisk)
                    )
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                    .glassSurface(padding: 0)
                } else {
                    ContentUnavailableView(
                        L10n.text("选择物理磁盘"),
                        systemImage: "internaldrive"
                    )
                }
            }
        }
    }

    private var physicalHealthDisks: [DiskActivity] {
        sortedDisks.filter(\.isPhysical)
    }

    private var healthDeviceNames: [String] {
        physicalHealthDisks.map(\.bsdName).filter { !$0.isEmpty }
    }

    private var healthDevices: [DiskHealthDeviceReference] {
        physicalHealthDisks.compactMap { disk in
            guard !disk.bsdName.isEmpty else { return nil }
            return DiskHealthDeviceReference(
                bsdName: disk.bsdName,
                registryID: disk.id
            )
        }
    }

    private var healthRefreshInProgress: Bool {
        healthDeviceNames.contains { name in
            if case .loading = store.diskHealth.state(for: name) { return true }
            return false
        }
    }

    private func refreshHealth() {
        Task {
            await store.diskHealth.refresh(devices: healthDevices, force: true)
        }
    }

    private func physicalDisks(for volume: VolumeInfo) -> [DiskActivity] {
        store.disks.filter {
            $0.isPhysical && volume.physicalDiskBSDNames.contains($0.bsdName)
        }
    }

    private var chartPoints: [ThroughputPoint] {
        guard let end = store.points.last?.timestamp else { return [] }
        let cutoff = end.addingTimeInterval(-store.selectedRange.seconds)
        let visible = store.points.filter { $0.timestamp >= cutoff }
        return downsampledChartPoints(visible, segment: { $0.segment }) {
            [$0.readBytesPerSecond, $0.writeBytesPerSecond]
        }
    }

    private func sharesPhysicalDevice(_ volume: VolumeInfo) -> Bool {
        store.volumes.contains { other in
            other.id != volume.id
                && !Set(other.physicalDiskBSDNames)
                    .isDisjoint(with: volume.physicalDiskBSDNames)
        }
    }

    private func volumeNames(for disk: DiskActivity) -> [String] {
        store.volumes
            .filter { $0.physicalDiskBSDNames.contains(disk.bsdName) }
            .map(\.name)
    }

    private var sortedDisks: [DiskActivity] {
        store.disks.sorted { lhs, rhs in
            let lhsIndex = store.volumes.firstIndex {
                $0.physicalDiskBSDNames.contains(lhs.bsdName)
            } ?? Int.max
            let rhsIndex = store.volumes.firstIndex {
                $0.physicalDiskBSDNames.contains(rhs.bsdName)
            } ?? Int.max
            if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
            if lhs.isPhysical != rhs.isPhysical { return lhs.isPhysical }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var allProcessSessions: [ProcessSession] {
        store.processes.flatMap(\.sessions)
    }

    private var processSessionTopology: String {
        allProcessSessions
            .map { "\($0.pid):\($0.startAbstime)" }
            .sorted()
            .joined(separator: "|")
    }
}

private enum DiskPageMode: String, CaseIterable, Identifiable {
    case activity
    case health

    var id: String { rawValue }
    var title: String {
        switch self {
        case .activity: L10n.text("实时活动")
        case .health: L10n.text("磁盘健康")
        }
    }
}

private struct DiskHealthDeviceRow: View {
    let disk: DiskActivity
    let volumeNames: [String]
    let state: DiskHealthState
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "internaldrive")
                .font(.title3)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(disk.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(volumeNames.isEmpty ? disk.bsdName : volumeNames.joined(separator: L10n.text("、")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            statusAccessory
        }
        .padding(.horizontal, 12)
        .frame(height: 64)
        .background(isSelected ? Color.accentColor.opacity(0.1) : .clear)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(Color.accentColor).frame(width: 3)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusAccessory: some View {
        switch state {
        case .idle, .loading:
            ProgressView().controlSize(.small)
        case .available(let snapshot):
            Image(systemName: statusSymbol(snapshot.assessment))
                .foregroundStyle(statusColor(snapshot.assessment))
        case .unsupported:
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.orange)
        case .disconnected:
            Image(systemName: "externaldrive.badge.xmark")
                .foregroundStyle(.secondary)
        }
    }

    private func statusSymbol(_ assessment: DiskHealthAssessment) -> String {
        switch assessment {
        case .criticalSMART, .criticalDeviceWarning, .temperatureWarning:
            "xmark.octagon.fill"
        case .spareBelowThreshold, .mediaErrors:
            "exclamationmark.triangle.fill"
        case .verified:
            "checkmark.circle.fill"
        case .partial:
            "info.circle"
        }
    }

    private func statusColor(_ assessment: DiskHealthAssessment) -> Color {
        switch assessment {
        case .criticalSMART, .criticalDeviceWarning, .temperatureWarning: .red
        case .spareBelowThreshold, .mediaErrors: .orange
        case .verified: .secondary
        case .partial: .secondary
        }
    }
}

private struct DiskHealthDetail: View {
    let diskName: String
    let bsdName: String
    let volumeNames: [String]
    let state: DiskHealthState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                stateContent
            }
            .padding(24)
            .frame(maxWidth: 880, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .frame(width: 42, height: 42)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 3) {
                Text(state.snapshot?.model ?? diskName)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                Text(volumeNames.isEmpty
                    ? bsdName
                    : L10n.format("物理设备 %@ · %@", bsdName, volumeNames.joined(separator: L10n.text("、"))))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch state {
        case .idle:
            healthLoading(previous: nil)
        case .loading(let previous):
            healthLoading(previous: previous)
        case .available(let snapshot):
            healthValues(snapshot, stale: false)
        case .unsupported(let snapshot):
            VStack(alignment: .leading, spacing: 10) {
                Label(L10n.text("当前连接未提供详细健康数据"), systemImage: "info.circle")
                    .font(.headline)
                Text(L10n.text("实时吞吐和容量监控仍然可用，不需要反复授权。"))
                    .foregroundStyle(.secondary)
                healthSource(snapshot)
            }
        case .failed(let previous):
            if let previous {
                VStack(alignment: .leading, spacing: 14) {
                    Label(L10n.text("本次读取失败，正在显示上次结果"), systemImage: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    healthValues(previous, stale: true)
                }
            } else {
                healthFailure(L10n.text("无法读取这块磁盘的健康数据"))
            }
        case .disconnected(let previous):
            if let previous {
                VStack(alignment: .leading, spacing: 14) {
                    Label(L10n.text("设备已断开，以下是上次结果"), systemImage: "externaldrive.badge.xmark")
                        .foregroundStyle(.secondary)
                    healthValues(previous, stale: true)
                }
            } else {
                healthFailure(L10n.text("设备已断开"))
            }
        }
    }

    private func healthLoading(previous: DiskHealthSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(L10n.text("正在读取设备健康数据…"))
            }
            if let previous {
                healthValues(previous, stale: true)
            } else {
                VStack(spacing: 10) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.08))
                            .frame(height: 24)
                    }
                }
                .frame(maxWidth: 560)
            }
        }
    }

    private func healthValues(_ snapshot: DiskHealthSnapshot, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HealthConclusionBand(
                title: healthConclusion(snapshot),
                symbol: healthConclusionSymbol(snapshot),
                color: healthConclusionColor(snapshot),
                staleText: stale
                    ? L10n.format(
                        "上次读取于 %@",
                        L10n.date(snapshot.sampledAt, date: .abbreviated, time: .standard)
                    )
                    : nil
            )

            let metrics = headlineMetrics(snapshot, stale: stale)
            if !metrics.isEmpty {
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: 140, maximum: 220),
                            spacing: 16,
                            alignment: .leading
                        )
                    ],
                    alignment: .leading,
                    spacing: 14
                ) {
                    ForEach(metrics) { metric in
                        HealthHeadlineMetric(item: metric)
                            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    }
                }
            }

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 28) {
                    deviceInformation(snapshot)
                    Divider()
                    reliabilityInformation(snapshot)
                }
                VStack(alignment: .leading, spacing: 24) {
                    deviceInformation(snapshot)
                    Divider()
                    reliabilityInformation(snapshot)
                }
            }

            healthSource(snapshot)
        }
    }

    private func deviceInformation(_ snapshot: DiskHealthSnapshot) -> some View {
        HealthDetailSection(
            title: "设备信息",
            symbol: "internaldrive",
            items: deviceDetails(snapshot)
        )
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func reliabilityInformation(_ snapshot: DiskHealthSnapshot) -> some View {
        HealthDetailSection(
            title: "运行与可靠性",
            symbol: "waveform.path.ecg",
            items: reliabilityDetails(snapshot)
        )
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func headlineMetrics(
        _ snapshot: DiskHealthSnapshot,
        stale: Bool
    ) -> [HealthDisplayItem] {
        var items: [HealthDisplayItem] = []
        if let bytes = snapshot.hostBytesWritten {
            items.append(.init(
                title: L10n.text("累计主机写入"),
                value: ByteRateFormatter.approximateBytes(bytes),
                symbol: "pencil.line",
                color: InstrumentDesign.ColorRole.diskWrite
            ))
        }
        if let used = snapshot.percentageUsed {
            items.append(.init(
                title: L10n.text("设备报告寿命消耗"),
                value: used == 0 ? L10n.text("低于 1%") : L10n.format("约 %d%%", Int(used)),
                symbol: "gauge.with.dots.needle.50percent",
                color: .teal
            ))
        }
        if let temperature = snapshot.temperatureCelsius {
            items.append(.init(
                title: L10n.text(stale ? "上次温度" : "当前温度"),
                value: "\(L10n.decimal(temperature, fractionDigits: 0))°C",
                symbol: "thermometer.medium",
                color: .blue
            ))
        }
        if let errors = snapshot.mediaErrors {
            let hasErrors = errors.high > 0 || errors.low > 0
            items.append(.init(
                title: L10n.text("介质错误"),
                value: counterText(errors),
                symbol: hasErrors ? "exclamationmark.triangle.fill" : "checkmark",
                color: hasErrors ? .red : .secondary
            ))
        }
        return Array(items.prefix(4))
    }

    private func deviceDetails(_ snapshot: DiskHealthSnapshot) -> [HealthDisplayItem] {
        var items: [HealthDisplayItem] = []
        if let connection = connectionText(snapshot) {
            items.append(.plain(title: L10n.text("连接方式"), value: connection))
        }
        if let capacity = snapshot.capacity {
            items.append(.plain(title: L10n.text("容量"), value: ByteRateFormatter.bytes(capacity)))
        }
        if let bytes = snapshot.hostBytesRead {
            items.append(.plain(
                title: L10n.text("累计主机读取"),
                value: ByteRateFormatter.approximateBytes(bytes)
            ))
        }
        if let hours = snapshot.powerOnHours {
            items.append(.plain(
                title: L10n.text("通电时间"),
                value: L10n.format("%@ 小时", counterText(hours))
            ))
        }
        if let cycles = snapshot.powerCycles {
            items.append(.plain(title: L10n.text("通电次数"), value: counterText(cycles)))
        }
        return items
    }

    private func reliabilityDetails(_ snapshot: DiskHealthSnapshot) -> [HealthDisplayItem] {
        var items: [HealthDisplayItem] = []
        if let spare = snapshot.availableSpare {
            let value = if let threshold = snapshot.availableSpareThreshold {
                L10n.format("%d%% · 阈值 %d%%", Int(spare), Int(threshold))
            } else {
                "\(spare)%"
            }
            items.append(.plain(
                title: L10n.text("可用备用空间"),
                value: value
            ))
        }
        if let errors = snapshot.mediaErrors {
            items.append(.plain(title: L10n.text("介质错误"), value: counterText(errors)))
        }
        if let entries = snapshot.errorLogEntries {
            items.append(.plain(title: L10n.text("错误日志记录"), value: counterText(entries)))
        }
        if let shutdowns = snapshot.unsafeShutdowns {
            items.append(.plain(title: L10n.text("异常断电"), value: counterText(shutdowns)))
        }
        return items
    }

    private func connectionText(_ snapshot: DiskHealthSnapshot) -> String? {
        switch snapshot.connectionKind {
        case .externalNVMe:
            L10n.text("外接 NVMe（雷电/USB4）")
        case .nvme:
            "NVMe"
        case .reported:
            snapshot.connection
        case .unavailable:
            nil
        }
    }

    private func healthSource(_ snapshot: DiskHealthSnapshot) -> some View {
        Text(L10n.format(
            "来源：%@ · %@",
            snapshot.source,
            L10n.date(snapshot.sampledAt, date: .abbreviated, time: .standard)
        ))
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func healthFailure(_ text: String) -> some View {
        ContentUnavailableView(
            text,
            systemImage: "exclamationmark.triangle",
            description: Text(L10n.text("实时吞吐与容量监控不受影响。"))
        )
    }

    private func healthConclusion(_ snapshot: DiskHealthSnapshot) -> String {
        switch snapshot.assessment {
        case .criticalSMART: return L10n.text("设备报告 SMART 异常")
        case .criticalDeviceWarning: return L10n.text("设备报告关键健康警告")
        case .temperatureWarning: return L10n.text("设备报告温度警告")
        case .spareBelowThreshold: return L10n.text("备用空间低于设备阈值")
        case .mediaErrors: return L10n.text("设备报告了介质错误")
        case .verified: return L10n.text("设备未报告 SMART 故障")
        case .partial: return L10n.text("设备提供了部分健康数据")
        }
    }

    private func healthConclusionSymbol(_ snapshot: DiskHealthSnapshot) -> String {
        switch healthSeverity(snapshot) {
        case .critical: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .normal: "checkmark.circle"
        case .partial: "info.circle"
        }
    }

    private func healthConclusionColor(_ snapshot: DiskHealthSnapshot) -> Color {
        switch healthSeverity(snapshot) {
        case .critical: .red
        case .warning: .orange
        case .normal: .primary
        case .partial: .secondary
        }
    }

    private func healthSeverity(_ snapshot: DiskHealthSnapshot) -> HealthSeverity {
        switch snapshot.assessment {
        case .criticalSMART, .criticalDeviceWarning, .temperatureWarning: .critical
        case .spareBelowThreshold, .mediaErrors: .warning
        case .verified: .normal
        case .partial: .partial
        }
    }

    private func counterText(_ value: UInt128Value) -> String {
        if value.high == 0 { return L10n.number(value.low) }
        return L10n.decimal(value.approximateDouble, fractionDigits: 0)
    }
}

private struct HealthDisplayItem: Identifiable {
    let title: String
    let value: String
    let symbol: String
    let color: Color

    var id: String { title }

    static func plain(title: String, value: String) -> Self {
        Self(title: title, value: value, symbol: "circle.fill", color: .secondary)
    }
}

private struct HealthConclusionBand: View {
    let title: String
    let symbol: String
    let color: Color
    let staleText: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                if let staleText {
                    Text(staleText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(color.opacity(0.055))
        .overlay(alignment: .leading) {
            Rectangle().fill(color).frame(width: 3)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HealthHeadlineMetric: View {
    let item: HealthDisplayItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(item.color)
                .frame(width: 30, height: 30)
                .background(item.color.opacity(0.11), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.value)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(item.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HealthDetailSection: View {
    let title: String
    let symbol: String
    let items: [HealthDisplayItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L10n.text(title), systemImage: symbol)
                .font(.headline)
            if items.isEmpty {
                Text(L10n.text("不可用"))
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                    ForEach(items) { item in
                        GridRow {
                            Text(item.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 100, alignment: .leading)
                            Text(item.value)
                                .font(.body.weight(.medium))
                                .monospacedDigit()
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

private enum HealthSeverity {
    case critical
    case warning
    case normal
    case partial
}

private struct DiskRow: View {
    let disk: DiskActivity
    let volumeNames: [String]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "internaldrive")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(disk.name)
                    .font(.body.weight(.medium))
                Text(deviceSubtitle)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            rateBlock(
                L10n.text("读取"),
                disk.readBytesPerSecond,
                color: InstrumentDesign.ColorRole.diskRead
            )
            rateBlock(
                L10n.text("写入"),
                disk.writeBytesPerSecond,
                color: InstrumentDesign.ColorRole.diskWrite
            )
            VStack(alignment: .trailing, spacing: 2) {
                Text(L10n.format(
                    "%d 次/秒",
                    Int(disk.readOperationsPerSecond + disk.writeOperationsPerSecond)
                ))
                    .monospacedDigit()
                Text(L10n.text("设备操作"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 90, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }

    private var deviceSubtitle: String {
        let kind = L10n.text(disk.isPhysical ? "物理设备" : "虚拟设备")
        guard !volumeNames.isEmpty else {
            return L10n.format("%@ · %@ · 未挂载", kind, disk.bsdName)
        }
        return L10n.format(
            "%@ · %@ · %@",
            kind,
            disk.bsdName,
            volumeNames.joined(separator: L10n.text("、"))
        )
    }

    private func rateBlock(_ title: String, _ value: Double, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(ByteRateFormatter.rate(value))
                .font(.system(.body, design: .monospaced, weight: .medium))
                .foregroundStyle(color)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 110, alignment: .trailing)
    }
}

private struct VolumeRow: View {
    let volume: VolumeInfo
    let disks: [DiskActivity]
    let sharesDevice: Bool
    let traceIsRunning: Bool
    let onTraceAccessSource: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: volume.isRemovable ? "externaldrive" : "internaldrive")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name)
                    .font(.body.weight(.medium))
                Text(volumeSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            Button(action: onTraceAccessSource) {
                Image(systemName: "scope")
            }
            .buttonStyle(AppIconButtonStyle(size: 30, isFramed: false))
            .contentShape(Rectangle())
            .help(L10n.text("追踪访问来源"))
            .accessibilityLabel(L10n.text("追踪访问来源"))
            .disabled(traceIsRunning || !volume.isLocal)
            if !volume.isLocal {
                EvidenceLabel(text: "网络卷", symbol: "network")
            } else if disks.isEmpty {
                Text(L10n.text("吞吐暂不可用"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                rateBlock(
                    L10n.text("读取"),
                    readRate,
                    color: InstrumentDesign.ColorRole.diskRead
                )
                rateBlock(
                    L10n.text("写入"),
                    writeRate,
                    color: InstrumentDesign.ColorRole.diskWrite
                )
            }
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(ByteRateFormatter.bytes(UInt64(max(0, volume.totalCapacity - volume.availableCapacity)))) / \(ByteRateFormatter.bytes(UInt64(max(0, volume.totalCapacity))))")
                    .font(.caption.monospaced())
                ProgressView(value: volume.usedFraction)
                    .frame(width: 150)
                    .tint(
                        volume.usedFraction > 0.9
                            ? InstrumentDesign.ColorRole.warning
                            : InstrumentDesign.ColorRole.cpu.opacity(0.78)
                    )
            }
        }
        .padding(.vertical, 7)
    }

    private var readRate: Double {
        disks.reduce(0) { $0 + $1.readBytesPerSecond }
    }

    private var writeRate: Double {
        disks.reduce(0) { $0 + $1.writeBytesPerSecond }
    }

    private var volumeSubtitle: String {
        guard !disks.isEmpty else { return volume.mountPath }
        let deviceNames = disks.map(\.name).joined(separator: " + ")
        let qualifier = sharesDevice ? L10n.text(" · 与其他卷共享设备吞吐") : ""
        return L10n.format("%@ · %@%@", volume.mountPath, deviceNames, qualifier)
    }

    private func rateBlock(_ title: String, _ value: Double, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(ByteRateFormatter.rate(value))
                .font(.system(.body, design: .monospaced, weight: .medium))
                .foregroundStyle(color)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 102, alignment: .trailing)
    }

}

private struct VolumeAccessTracePanel: View {
    let store: VolumeAccessTraceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if needsStatusBand { statusBand }
            metrics
            HSplitView {
                VolumeAccessSourceTable(items: store.sources)
                    .frame(minWidth: 440, idealWidth: 620, minHeight: 300)
                VolumeAccessEventTable(items: store.events)
                    .frame(minWidth: 360, idealWidth: 460, minHeight: 300)
            }
            .frame(height: 340)
            semanticsNote
        }
        .padding(.top, 4)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.magnifyingglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 42, height: 42)
                .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(store.selection?.displayName ?? "")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    VolumeTraceStateLabel(state: store.state)
                }
                Text(store.selection?.mountPath ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(store.selection?.mountPath ?? "")
            }
            Spacer(minLength: 12)
            traceActions
        }
    }

    private var traceActions: some View {
        HStack(spacing: 8) {
            if store.state == .stopping || store.state == .stopUnconfirmed {
                ProgressView()
                    .controlSize(.small)
                    .help(L10n.text("正在确认追踪已结束"))
            } else if store.isRunning {
                Button(role: .destructive, action: store.stop) {
                    Label(L10n.text("停止追踪"), systemImage: "stop.fill")
                }
                .buttonStyle(AppActionButtonStyle(kind: .destructive))
            } else if canStart {
                Button(action: store.start) {
                    Label(
                        L10n.text(store.state == .stopped ? "重新开始" : "开始追踪"),
                        systemImage: "record.circle"
                    )
                }
                .buttonStyle(AppActionButtonStyle(kind: .primary))
            }

            Menu {
                Button(action: store.clear) {
                    Label(L10n.text("清除本次结果"), systemImage: "eraser")
                }
                .disabled(store.isRunning || store.startedAt == nil)
                Button(action: store.removeTarget) {
                    Label(L10n.text("移除目标"), systemImage: "xmark")
                }
                .disabled(store.isRunning)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help(L10n.text("更多操作"))
        }
    }

    private var statusBand: some View {
        HStack(spacing: 12) {
            Image(systemName: statusSymbol)
                .font(.title3)
                .foregroundStyle(statusColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.headline)
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            statusActions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(statusColor.opacity(0.06))
        .overlay(alignment: .leading) {
            Rectangle().fill(statusColor).frame(width: 3)
        }
    }

    @ViewBuilder
    private var statusActions: some View {
        switch store.state {
        case .permissionRequired:
            Button(L10n.text("启用追踪"), action: store.requestPermission)
                .buttonStyle(AppActionButtonStyle(kind: .primary))
        case .waitingForApproval:
            Button(action: store.openApprovalSettings) {
                Label(L10n.text("打开登录项设置"), systemImage: "gearshape")
            }
            .buttonStyle(AppActionButtonStyle(kind: .primary))
        case .repairAvailable:
            Button(action: store.repairAndRetry) {
                Label(L10n.text("修复并重试"), systemImage: "wrench.and.screwdriver")
            }
            .buttonStyle(AppActionButtonStyle(kind: .primary))
        case .installationRequired:
            Button(action: store.openInstallationLocation) {
                Label(L10n.text("打开安装窗口"), systemImage: "folder")
            }
            .buttonStyle(AppActionButtonStyle(kind: .primary))
        case .repairing, .stopping, .stopUnconfirmed:
            ProgressView().controlSize(.small)
        case .failed:
            Button(action: store.start) {
                Label(L10n.text("重试"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(AppActionButtonStyle(kind: .secondary))
        default:
            EmptyView()
        }
    }

    private var metrics: some View {
        HStack(spacing: 14) {
            VolumeTraceMetric(
                title: "首次观察",
                value: firstEventText,
                symbol: "flag.checkered",
                color: .blue
            )
            Divider().frame(height: 42)
            VolumeTraceMetric(
                title: "元数据访问",
                value: store.metadataEventCount.map { L10n.number($0) } ?? L10n.text("尚未开始"),
                symbol: "list.bullet.rectangle",
                color: .indigo
            )
            Divider().frame(height: 42)
            VolumeTraceMetric(
                title: "请求读 / 写",
                value: requestBytesText,
                symbol: "arrow.left.arrow.right",
                color: .orange
            )
            Divider().frame(height: 42)
            VolumeTraceMetric(
                title: "已运行",
                value: elapsedText,
                symbol: "timer",
                color: .teal
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.secondary.opacity(0.035))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 0.5)
        }
    }

    private var semanticsNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: coverageSymbol)
                .foregroundStyle(coverageColor)
            Text(coverageText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var canStart: Bool {
        switch store.state {
        case .ready, .stopped: true
        default: false
        }
    }

    private var needsStatusBand: Bool {
        switch store.state {
        case .permissionRequired, .waitingForApproval, .repairing,
                .repairAvailable, .installationRequired, .failed, .unsupportedFormat,
                .stopping, .stopUnconfirmed:
            true
        default: false
        }
    }

    private var statusTitle: String {
        switch store.state {
        case .permissionRequired: L10n.text("需要启用文件访问追踪")
        case .waitingForApproval: L10n.text("等待你在系统设置中批准")
        case .repairing: L10n.text("正在更新追踪组件")
        case .repairAvailable: L10n.text("追踪组件未能启动")
        case .stopping: L10n.text("正在停止追踪")
        case .stopUnconfirmed: L10n.text("正在确认追踪已结束")
        case .installationRequired: L10n.text("需要先安装到应用程序文件夹")
        case .unsupportedFormat: L10n.text("当前 macOS 输出格式暂不受支持")
        case .failed(let message): message
        default: ""
        }
    }

    private var statusDetail: String {
        switch store.state {
        case .permissionRequired:
            L10n.text("开始后会进行短时系统级文件访问追踪，只显示命中此卷的事件。")
        case .waitingForApproval:
            L10n.text("在“登录项与扩展”中允许 FindDiskKiller 后返回这里，追踪会自动开始。")
        case .repairing:
            L10n.text("正在替换旧版追踪组件，完成后会自动继续。")
        case .repairAvailable:
            L10n.text("组件已启用但未能启动。请直接修复，无需重复切换系统设置；已有结果会保留。")
        case .stopping:
            L10n.text("仍可检查更新；如需安装，将在追踪完全停止后自动继续。")
        case .stopUnconfirmed:
            L10n.text("仍可检查更新；确认后台追踪结束前不会开始安装。")
        case .installationRequired(let isDiskImage):
            isDiskImage
                ? L10n.text("请在安装窗口中将 FindDiskKiller 拖入“应用程序”，然后重新打开。")
                : L10n.text("请将 FindDiskKiller 移入“应用程序”文件夹，然后重新打开。")
        case .unsupportedFormat:
            L10n.text("为了避免显示看似精确但含义错误的结果，本次追踪已停止。")
        case .failed:
            L10n.text("请检查追踪组件状态后重试；已有结果仍保留在当前会话中。")
        default:
            ""
        }
    }

    private var statusSymbol: String {
        switch store.state {
        case .permissionRequired, .waitingForApproval: "lock.shield"
        case .repairing, .stopping, .stopUnconfirmed: "arrow.triangle.2.circlepath"
        case .repairAvailable: "wrench.and.screwdriver"
        case .installationRequired: "folder.badge.plus"
        case .unsupportedFormat: "doc.badge.ellipsis"
        default: "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch store.state {
        case .permissionRequired, .waitingForApproval, .repairing, .stopping: .blue
        default: .orange
        }
    }

    private var firstEventText: String {
        store.firstEventAt.map { L10n.date($0, date: .omitted, time: .standard) }
            ?? L10n.text("等待访问")
    }

    private var requestBytesText: String {
        guard let read = store.requestedReadBytes,
              let write = store.requestedWriteBytes
        else { return L10n.text("尚未开始") }
        return "\(ByteRateFormatter.bytes(read)) / \(ByteRateFormatter.bytes(write))"
    }

    private var elapsedText: String {
        guard store.startedAt != nil else { return L10n.text("尚未开始") }
        let seconds = Int(store.elapsed)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var coverageText: String {
        let boundary = L10n.text("结果表示追踪期间最早观察到的卷访问，不等同于硬盘盒物理唤醒的绝对证明。")
        switch store.coverage {
        case .complete:
            return boundary
        case .partial(let count):
            return L10n.format("%@ 本次有 %llu 条事件未能完整处理，列表可能遗漏。", boundary, count)
        case .unsupportedFormat:
            return L10n.text("当前系统输出格式无法可靠解析，没有生成访问来源结果。")
        }
    }

    private var coverageSymbol: String {
        switch store.coverage {
        case .complete: "info.circle"
        case .partial, .unsupportedFormat: "exclamationmark.triangle"
        }
    }

    private var coverageColor: Color {
        switch store.coverage {
        case .complete: .secondary
        case .partial, .unsupportedFormat: .orange
        }
    }
}

private struct VolumeTraceMetric: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(.callout, design: .monospaced, weight: .semibold))
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(L10n.text(title))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct VolumeTraceStateLabel: View {
    let state: FileAccessTraceRunState

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.09), in: Capsule())
    }

    private var title: String {
        switch state {
        case .running: L10n.text("追踪中")
        case .starting: L10n.text("正在开始")
        case .repairing: L10n.text("正在更新")
        case .stopped: L10n.text("已停止")
        case .repairAvailable, .installationRequired, .failed, .unsupportedFormat:
            L10n.text("需要处理")
        default: L10n.text("准备就绪")
        }
    }

    private var color: Color {
        switch state {
        case .running: .green
        case .starting, .repairing: .blue
        case .repairAvailable, .installationRequired, .failed, .unsupportedFormat: .orange
        default: .secondary
        }
    }
}

private struct VolumeAccessSourceRow: Identifiable, Equatable {
    let id: String
    let name: String
    let pid: Int32?
    let firstEventAt: Date
    let firstOperation: String
    let samplePath: String
    let metadataCount: Int
    let readCount: Int
    let writeCount: Int
    let readBytes: UInt64
    let writeBytes: UInt64

    init(_ item: VolumeAccessTraceSourceSummary) {
        id = item.id
        name = item.process.displayName
        pid = item.process.pid
        firstEventAt = item.firstEventAt
        firstOperation = item.firstOperation
        samplePath = item.samplePath
        metadataCount = item.metadataEventCount
        readCount = item.readEventCount
        writeCount = item.writeEventCount
        readBytes = item.requestedReadBytes
        writeBytes = item.requestedWriteBytes
    }
}

private struct VolumeAccessSourceTable: View {
    let items: [VolumeAccessTraceSourceSummary]
    @State private var rows: [VolumeAccessSourceRow] = []
    @State private var sortOrder = [
        KeyPathComparator(\VolumeAccessSourceRow.firstEventAt, order: .forward)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            volumeTraceTableHeading("最早访问来源", count: rows.count, symbol: "person.crop.square")
            Divider()
            Table(rows, sortOrder: $sortOrder) {
                TableColumn(L10n.text("应用或进程"), value: \.name) { row in
                    HStack(spacing: 8) {
                        VolumeTraceProcessIcon(pid: row.pid)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name).lineLimit(1)
                            Text(processSubtitle(row))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .width(min: 160, ideal: 210)
                TableColumn(L10n.text("首次"), value: \.firstEventAt) { row in
                    Text(row.firstEventAt, format: .dateTime.hour().minute().second())
                        .monospacedDigit()
                }
                .width(min: 82, ideal: 96)
                TableColumn(L10n.text("证据"), value: \.firstOperation) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.firstOperation)
                            .font(.callout.monospaced())
                        Text(privateVolumeTracePath(row.samplePath))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help(row.samplePath)
                }
                .width(min: 200, ideal: 280)
                TableColumn(L10n.text("读 / 写"), value: \.writeBytes) { row in
                    Text("\(ByteRateFormatter.bytes(row.readBytes)) / \(ByteRateFormatter.bytes(row.writeBytes))")
                        .monospacedDigit()
                }
                .width(min: 120, ideal: 150)
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(
                        L10n.text("等待这个卷出现访问事件"),
                        systemImage: "scope"
                    )
                    .controlSize(.small)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 0.5)
        }
        .onChange(of: items, initial: true) { _, newValue in
            rows = newValue.map(VolumeAccessSourceRow.init).sorted(using: sortOrder)
        }
        .onChange(of: sortOrder) { _, newValue in
            rows.sort(using: newValue)
        }
    }

    private func processSubtitle(_ row: VolumeAccessSourceRow) -> String {
        if let pid = row.pid {
            return L10n.format("进程 ID %d · %@ 次事件", pid, L10n.number(eventCount(row)))
        }
        return L10n.format("%@ 次事件", L10n.number(eventCount(row)))
    }

    private func eventCount(_ row: VolumeAccessSourceRow) -> Int {
        row.metadataCount + row.readCount + row.writeCount
    }
}

private struct VolumeAccessEventRow: Identifiable, Equatable {
    let id: String
    let timestamp: Date
    let operation: String
    let category: VolumeAccessTraceOperationCategory
    let path: String
    let processName: String

    init(_ item: VolumeAccessTraceEventSummary) {
        id = item.id
        timestamp = item.timestamp
        operation = item.operation
        category = item.category
        path = item.path
        processName = item.process.displayName
    }
}

private struct VolumeAccessEventTable: View {
    let items: [VolumeAccessTraceEventSummary]
    @State private var rows: [VolumeAccessEventRow] = []
    @State private var sortOrder = [
        KeyPathComparator(\VolumeAccessEventRow.timestamp, order: .forward)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            volumeTraceTableHeading("访问时间线", count: rows.count, symbol: "clock")
            Divider()
            Table(rows, sortOrder: $sortOrder) {
                TableColumn(L10n.text("时间"), value: \.timestamp) { row in
                    Text(row.timestamp, format: .dateTime.hour().minute().second())
                        .monospacedDigit()
                }
                .width(min: 82, ideal: 96)
                TableColumn(L10n.text("操作"), value: \.operation) { row in
                    Label(row.operation, systemImage: symbol(for: row.category))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(color(for: row.category))
                }
                .width(min: 100, ideal: 120)
                TableColumn(L10n.text("来源"), value: \.processName) { row in
                    Text(row.processName).lineLimit(1)
                }
                .width(min: 110, ideal: 150)
                TableColumn(L10n.text("路径"), value: \.path) { row in
                    Text(privateVolumeTracePath(row.path))
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.path)
                }
                .width(min: 180, ideal: 260)
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(
                        L10n.text("还没有命中的访问记录"),
                        systemImage: "list.bullet.rectangle"
                    )
                    .controlSize(.small)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 0.5)
        }
        .onChange(of: items, initial: true) { _, newValue in
            rows = newValue.map(VolumeAccessEventRow.init).sorted(using: sortOrder)
        }
        .onChange(of: sortOrder) { _, newValue in
            rows.sort(using: newValue)
        }
    }

    private func symbol(for category: VolumeAccessTraceOperationCategory) -> String {
        switch category {
        case .metadata: "list.bullet.rectangle"
        case .read: "eye"
        case .write: "pencil.line"
        }
    }

    private func color(for category: VolumeAccessTraceOperationCategory) -> Color {
        switch category {
        case .metadata: .indigo
        case .read: InstrumentDesign.ColorRole.diskRead
        case .write: InstrumentDesign.ColorRole.diskWrite
        }
    }
}

private struct VolumeTraceProcessIcon: View {
    let pid: Int32?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "terminal")
                    .resizable()
                    .scaledToFit()
                    .padding(5)
                    .foregroundStyle(.secondary)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .frame(width: 24, height: 24)
        .task(id: pid) {
            guard let pid else { return }
            image = NSRunningApplication(processIdentifier: pid_t(pid))?.icon
        }
        .accessibilityHidden(true)
    }
}

@MainActor
private func volumeTraceTableHeading(_ title: String, count: Int, symbol: String) -> some View {
    HStack(spacing: 8) {
        Image(systemName: symbol).foregroundStyle(.secondary)
        Text(L10n.text(title)).font(.headline)
        Spacer()
        Text(L10n.number(count))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 12)
    .frame(height: 42)
}

private func privateVolumeTracePath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    guard path == home || path.hasPrefix(home + "/") else { return path }
    return "~" + path.dropFirst(home.count)
}
