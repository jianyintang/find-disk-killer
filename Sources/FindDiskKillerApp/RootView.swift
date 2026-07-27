import FindDiskKillerCore
import SwiftUI

enum AppSection: String, CaseIterable, Hashable, Identifiable, Sendable {
    case overview = "现在"
    case reports = "历史分析"
    case disks = "磁盘"
    case processes = "应用"

    var id: String { rawValue }
    var title: String { L10n.text(rawValue) }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .disks: "internaldrive"
        case .processes: "square.stack.3d.up"
        case .reports: "chart.xyaxis.line"
        }
    }
}

struct RootView: View {
    let store: MonitorStore
    let processDetailWindows: ProcessDetailWindowCoordinator
    let history: HistoryModel
    @State private var requestedSection: AppSection = .overview
    @State private var loadedSection: AppSection = .overview
    @State private var sectionSnapshots: [AppSection: SectionPreviewSnapshot] = [:]
    @State private var processSearchText = ""

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: sidebarSelection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationTitle("FindDiskKiller")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 240)
        } detail: {
            detail
                .toolbar { StatusToolbar(store: store) }
                .task(id: requestedSection) {
                    await loadRequestedSection()
                }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if requestedSection == loadedSection {
            loadedDetail
        } else {
            SectionNavigationPlaceholder(
                section: requestedSection,
                snapshot: sectionSnapshots[requestedSection],
                processSearchText: $processSearchText
            )
        }
    }

    @ViewBuilder
    private var loadedDetail: some View {
        switch loadedSection {
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
        case .reports:
            HistoryReportView(history: history)
        }
    }

    private var sidebarSelection: Binding<AppSection?> {
        Binding(
            get: { requestedSection },
            set: { newValue in
                guard let newValue, newValue != requestedSection else { return }
                requestedSection = newValue
            }
        )
    }

    private func loadRequestedSection() async {
        let target = requestedSection
        guard target != loadedSection else { return }
        let departing = loadedSection

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
    let cpu: String
    let totalWrite: String
    let currentWrite: String
    let peakWrite: String
    let download: String
    let upload: String

    init(_ process: ProcessActivity) {
        id = process.id
        name = process.localizedDisplayName
        cpu = PercentFormatter.cpu(process.currentCPUPercent)
        totalWrite = ByteRateFormatter.bytes(process.totalWriteBytes)
        currentWrite = ByteRateFormatter.rate(process.currentWriteBytesPerSecond)
        peakWrite = ByteRateFormatter.rate(process.peakWriteBytesPerSecond)
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
            name: "Application activity",
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
        cpu: String,
        totalWrite: String,
        currentWrite: String,
        peakWrite: String,
        download: String,
        upload: String
    ) {
        self.id = id
        self.name = name
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
    @Binding var processSearchText: String

    var body: some View {
        Group {
            if section == .processes {
                processPlaceholder
                    .searchable(
                        text: $processSearchText,
                        prompt: L10n.text("搜索应用或进程")
                    )
            } else {
                resourcePlaceholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(section.title)
    }

    private var statusLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: snapshot == nil ? "clock" : "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            if let snapshot {
                Text(L10n.format(
                    "正在刷新 · 上次结果 %@",
                    snapshot.capturedAt.formatted(date: .omitted, time: .standard)
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

    private var processPlaceholder: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(
                    L10n.text("时间范围"),
                    selection: Binding.constant(SampleRange.minute)
                ) {
                    ForEach(SampleRange.allCases) { range in
                        Text(range.localizedTitle).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                .redacted(reason: .placeholder)
                .disabled(true)
                Spacer()
                statusLabel
            }
            .padding(16)

            Divider()
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    previewTableHeader
                    Divider()
                    ForEach(previewProcesses) { process in
                        previewProcessRow(process)
                        Divider().padding(.leading, 14)
                    }
                }
                .frame(width: 909, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
        HStack(spacing: 0) {
            previewHeader("应用", width: 250, alignment: .leading)
            previewHeader("CPU · 5 秒", width: 94)
            previewHeader("写入总量", width: 105)
            previewHeader("当前写入", width: 108)
            previewHeader("写入峰值", width: 108)
            previewHeader("下载平均", width: 108)
            previewHeader("上传平均", width: 108)
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
        HStack(spacing: 0) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 26, height: 26)
                Text(process.name).lineLimit(1)
            }
            .frame(width: 250, alignment: .leading)
            previewValue(process.cpu, width: 94)
            previewValue(process.totalWrite, width: 105)
            previewValue(process.currentWrite, width: 108)
            previewValue(process.peakWrite, width: 108)
            previewValue(process.download, width: 108)
            previewValue(process.upload, width: 108)
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
