import FindDiskKillerCore
import SwiftUI

struct DisksView: View {
    let store: MonitorStore
    let fileAccessTrace: FileAccessTraceStore
    @State private var showHardwareDetails = true
    @State private var selectedMode: DiskPageMode = .activity
    @State private var selectedHealthDisk: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(L10n.text("磁盘视图"), selection: $selectedMode) {
                    ForEach(DiskPageMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 390)
                Spacer()
                if selectedMode == .health {
                    Button {
                        Task {
                            await store.diskHealth.refresh(
                                devices: healthDevices,
                                force: true
                            )
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help(L10n.text("重新读取健康数据"))
                    .disabled(healthRefreshInProgress)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)

            Divider()

            switch selectedMode {
            case .activity:
                activityContent
            case .health:
                healthContent
            case .trace:
                FileAccessTraceView(store: fileAccessTrace)
            }
        }
        .task(id: healthDevices) {
            if selectedHealthDisk == nil {
                selectedHealthDisk = healthDeviceNames.first
            }
            await store.diskHealth.refresh(devices: healthDevices)
        }
        .navigationTitle(L10n.text("磁盘"))
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
                        color: .teal
                    )
                    Divider().frame(height: 38)
                    MetricValue(
                        title: "写入 · 最近 5 秒",
                        value: store.isDiskAvailable
                            ? ByteRateFormatter.rate(store.currentWriteRate)
                            : "采样缺口",
                        symbol: "pencil.line",
                        color: .orange
                    )
                    Divider().frame(height: 38)
                    MetricValue(
                        title: "已挂载卷",
                        value: store.volumes.count.formatted(),
                        symbol: "externaldrive.connected.to.line.below",
                        color: .blue
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeading("物理设备总吞吐", subtitle: "虚拟磁盘不计入总量")
                    MonitorChart(points: chartPoints, height: 220)
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeading("已挂载卷", subtitle: "卷名直接对应底层设备的实时吞吐")
                    ForEach(store.volumes) { volume in
                        VolumeRow(
                            volume: volume,
                            disks: physicalDisks(for: volume),
                            sharesDevice: sharesPhysicalDevice(volume)
                        )
                        Divider()
                    }
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
            }
            .padding(22)
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
                        Text(physicalHealthDisks.count.formatted())
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
                .frame(minWidth: 230, idealWidth: 270, maxWidth: 320)

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
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                } else if let selectedHealthDisk,
                          let snapshot = store.diskHealth.state(for: selectedHealthDisk).snapshot {
                    DiskHealthDetail(
                        diskName: snapshot.model,
                        bsdName: selectedHealthDisk,
                        volumeNames: [],
                        state: store.diskHealth.state(for: selectedHealthDisk)
                    )
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
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
}

private enum DiskPageMode: String, CaseIterable, Identifiable {
    case activity
    case health
    case trace

    var id: String { rawValue }
    var title: String {
        switch self {
        case .activity: L10n.text("实时活动")
        case .health: L10n.text("磁盘健康")
        case .trace: L10n.text("文件访问追踪")
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
                        snapshot.sampledAt.formatted(date: .abbreviated, time: .standard)
                    )
                    : nil
            )

            let metrics = headlineMetrics(snapshot, stale: stale)
            if !metrics.isEmpty {
                HStack(spacing: 16) {
                    ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                        if index > 0 { Divider().frame(height: 42) }
                        HealthHeadlineMetric(item: metric)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 28) {
                HealthDetailSection(
                    title: "设备信息",
                    symbol: "internaldrive",
                    items: deviceDetails(snapshot)
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)

                Divider()

                HealthDetailSection(
                    title: "运行与可靠性",
                    symbol: "waveform.path.ecg",
                    items: reliabilityDetails(snapshot)
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            healthSource(snapshot)
        }
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
                color: .orange
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
                value: String(format: "%.0f°C", temperature),
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
            snapshot.sampledAt.formatted(date: .abbreviated, time: .standard)
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
        if value.high == 0 { return value.low.formatted() }
        return String(format: "%.0f", value.approximateDouble)
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
            rateBlock(L10n.text("读取"), disk.readBytesPerSecond, color: .teal)
            rateBlock(L10n.text("写入"), disk.writeBytesPerSecond, color: .orange)
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
            if !volume.isLocal {
                EvidenceLabel(text: "网络卷", symbol: "network")
            } else if disks.isEmpty {
                Text(L10n.text("吞吐暂不可用"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                rateBlock(L10n.text("读取"), readRate, color: .teal)
                rateBlock(L10n.text("写入"), writeRate, color: .orange)
            }
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(ByteRateFormatter.bytes(UInt64(max(0, volume.totalCapacity - volume.availableCapacity)))) / \(ByteRateFormatter.bytes(UInt64(max(0, volume.totalCapacity))))")
                    .font(.caption.monospaced())
                ProgressView(value: volume.usedFraction)
                    .frame(width: 150)
                    .tint(volume.usedFraction > 0.9 ? .red : .accentColor)
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
