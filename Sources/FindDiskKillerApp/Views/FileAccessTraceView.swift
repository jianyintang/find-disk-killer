import AppKit
import Charts
import FindDiskKillerCore
import SwiftUI

struct FileAccessTraceView: View {
    let store: FileAccessTraceStore
    let contextProcessName: String?
    let onBack: (() -> Void)?

    init(
        store: FileAccessTraceStore,
        contextProcessName: String? = nil,
        onBack: (() -> Void)? = nil
    ) {
        self.store = store
        self.contextProcessName = contextProcessName
        self.onBack = onBack
    }

    var body: some View {
        Group {
            if store.selection == nil {
                TraceTargetPicker(onChoose: chooseTarget)
            } else {
                traceWorkspace
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            store.refreshPermissionStatus()
        }
        .onAppear {
            guard onBack != nil else { return }
            store.start()
        }
        .onDisappear {
            guard onBack != nil else { return }
            store.endEphemeralSession()
        }
    }

    private var traceWorkspace: some View {
        VStack(spacing: 0) {
            if let onBack {
                HStack(spacing: 12) {
                    Button(action: onBack) {
                        Label(L10n.text("返回文件活动"), systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    Spacer()
                    Text(L10n.text("目录读写追踪"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .frame(height: 44)
                Divider()
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    targetHeader
                    if contextProcessName != nil { applicationContextNote }
                    if needsStatusBand { statusBand }
                    measurementRail
                    TraceRateChart(points: store.ratePoints)
                    traceTables
                    semanticsNote
                }
                .padding(22)
            }
        }
    }

    private var applicationContextNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "scope")
                .foregroundStyle(Color.accentColor)
            Text(L10n.format(
                "这里仅统计 %@ 当前进程组在此目录内向系统请求的读写。",
                contextProcessName ?? ""
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.055))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.accentColor).frame(width: 3)
        }
    }

    private var targetHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: store.selection?.kind == .directory ? "folder.fill" : "doc.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 42, height: 42)
                .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(store.selection?.displayName ?? "")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    TraceStateLabel(state: store.state)
                }
                Text(store.selection?.privatePath ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(store.selection?.privatePath ?? "")
            }
            Spacer(minLength: 12)
            traceActions
        }
    }

    private var traceActions: some View {
        HStack(spacing: 8) {
            if onBack == nil {
                Button(action: chooseTarget) {
                    Label(L10n.text("更换目标"), systemImage: "folder.badge.gearshape")
                }
                .disabled(store.isRunning)
            }

            if store.isRunning {
                Button(role: .destructive, action: store.stop) {
                    Label(L10n.text("停止追踪"), systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else if canStart {
                Button(action: store.start) {
                    Label(
                        L10n.text(store.state == .stopped ? "重新开始" : "开始追踪"),
                        systemImage: "record.circle"
                    )
                }
                .buttonStyle(.borderedProminent)
            }

            Menu {
                Button(action: store.clear) {
                    Label(L10n.text("清除本次结果"), systemImage: "eraser")
                }
                .disabled(store.isRunning || store.startedAt == nil)
                if onBack == nil {
                    Button(action: store.removeTarget) {
                        Label(L10n.text("移除目标"), systemImage: "xmark")
                    }
                    .disabled(store.isRunning)
                }
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
                .buttonStyle(.borderedProminent)
        case .waitingForApproval:
            Button(action: store.openApprovalSettings) {
                Label(L10n.text("打开登录项设置"), systemImage: "gearshape")
            }
            .buttonStyle(.borderedProminent)
        case .repairAvailable:
            Button(action: store.repairAndRetry) {
                Label(L10n.text("修复并重试"), systemImage: "wrench.and.screwdriver")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("trace.repairAndRetry")
        case .installationRequired:
            Button(action: store.openInstallationLocation) {
                Label(L10n.text("打开安装窗口"), systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
        case .repairing:
            ProgressView()
                .controlSize(.small)
        case .failed:
            Button(action: store.start) {
                Label(L10n.text("重试"), systemImage: "arrow.clockwise")
            }
        default:
            EmptyView()
        }
    }

    private var measurementRail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                TraceMetric(
                    title: "累计请求读取",
                    value: bytes(store.requestedReadBytes),
                    symbol: "eye",
                    color: .teal
                )
                Divider().frame(height: 42)
                TraceMetric(
                    title: "累计请求写入",
                    value: bytes(store.requestedWriteBytes),
                    symbol: "pencil.line",
                    color: .orange
                )
                Divider().frame(height: 42)
                TraceMetric(
                    title: "已运行",
                    value: elapsedText,
                    symbol: "timer",
                    color: .blue
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            HStack(spacing: 14) {
                TraceMetric(
                    title: "当前请求读取 · 5 秒",
                    value: rate(store.currentReadBytesPerSecond),
                    symbol: "arrow.down.to.line",
                    color: .teal
                )
                Divider().frame(height: 42)
                TraceMetric(
                    title: "当前请求写入 · 5 秒",
                    value: rate(store.currentWriteBytesPerSecond),
                    symbol: "arrow.right.to.line",
                    color: .orange
                )
                Divider().frame(height: 42)
                TraceMetric(
                    title: "会话峰值 · 读 / 写",
                    value: peakText,
                    symbol: "waveform.path.ecg",
                    color: .purple
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Color.secondary.opacity(0.035))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 0.5)
        }
    }

    private var traceTables: some View {
        HSplitView {
            TraceFileTable(items: store.files)
                .frame(minWidth: 440, idealWidth: 590, minHeight: 320)
            TraceProcessTable(items: store.processes)
                .frame(minWidth: 300, idealWidth: 360, minHeight: 320)
        }
        .frame(height: 360)
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
                .repairAvailable, .installationRequired, .failed, .unsupportedFormat:
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
        case .installationRequired: L10n.text("需要先安装到应用程序文件夹")
        case .unsupportedFormat: L10n.text("当前 macOS 输出格式暂不受支持")
        case .failed(let message): message
        default: ""
        }
    }

    private var statusDetail: String {
        switch store.state {
        case .permissionRequired:
            L10n.text("点击启用后，macOS 会请求一次管理员确认。FindDiskKiller 不会在后台自行申请。")
        case .waitingForApproval:
            L10n.text("在“登录项与扩展”中允许 FindDiskKiller 后返回这里，追踪会自动开始。")
        case .repairing:
            L10n.text("正在替换旧版追踪组件，完成后会自动继续。")
        case .repairAvailable:
            L10n.text("组件已启用但未能启动。请直接修复，无需重复切换系统设置；已有结果会保留。")
        case .installationRequired(let isDiskImage):
            isDiskImage
                ? L10n.text("请在安装窗口中将 FindDiskKiller 拖入“应用程序”，然后重新打开。")
                : L10n.text("请将 FindDiskKiller 移入“应用程序”文件夹，然后重新打开。")
        case .unsupportedFormat:
            L10n.text("为了避免显示看似精确但含义错误的数字，本次结果已停止统计。")
        case .failed:
            L10n.text("请检查追踪组件状态后重试；已有结果仍保留在当前会话中。")
        default: ""
        }
    }

    private var statusSymbol: String {
        switch store.state {
        case .permissionRequired, .waitingForApproval: "lock.shield"
        case .repairing: "arrow.triangle.2.circlepath"
        case .repairAvailable: "wrench.and.screwdriver"
        case .installationRequired: "folder.badge.plus"
        case .unsupportedFormat: "doc.badge.ellipsis"
        default: "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch store.state {
        case .permissionRequired, .waitingForApproval, .repairing: .blue
        default: .orange
        }
    }

    private var coverageText: String {
        let boundary = L10n.text("这里统计应用向系统请求的读写量；缓存、APFS 写回、压缩与 CoW 会使它和物理磁盘吞吐不同。")
        switch store.coverage {
        case .complete:
            return boundary
        case .partial(let count):
            return L10n.format("%@ 本次有 %llu 条事件未能完整处理，累计值可能偏低。", boundary, count)
        case .unsupportedFormat:
            return L10n.text("当前系统输出格式无法可靠解析，没有生成读写量结果。")
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

    private var elapsedText: String {
        guard store.startedAt != nil else { return L10n.text("尚未开始") }
        let seconds = Int(store.elapsed)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var peakText: String {
        guard let read = store.peakReadBytesPerSecond,
              let write = store.peakWriteBytesPerSecond
        else { return L10n.text("尚未开始") }
        return "\(ByteRateFormatter.rate(Double(read))) / \(ByteRateFormatter.rate(Double(write)))"
    }

    private func bytes(_ value: UInt64?) -> String {
        value.map(ByteRateFormatter.bytes) ?? L10n.text("尚未开始")
    }

    private func rate(_ value: Double?) -> String {
        value.map(ByteRateFormatter.rate) ?? L10n.text("尚未开始")
    }

    private func chooseTarget() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择要追踪的文件或目录")
        panel.prompt = L10n.text("选择")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in store.select(url) }
        }
    }
}

private struct TraceTargetPicker: View {
    let onChoose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "scope")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 52, height: 52)
                    .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.text("追踪一个文件或目录"))
                        .font(.title2.weight(.semibold))
                    Text(L10n.text("查看选定时段内的请求读写量、实时速率、活跃文件，以及访问它的应用。"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 20)
                Button(action: onChoose) {
                    Label(L10n.text("选择文件或目录"), systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Divider()

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "hand.raised")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("路径只在本次会话中处理"))
                        .font(.headline)
                    Text(L10n.text("完整路径不会上传或默认保存。开始追踪前不会申请管理员批准。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 900, alignment: .leading)
    }
}

private struct TraceStateLabel: View {
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

private struct TraceMetric: View {
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

private struct TraceRateChart: View {
    let points: [FileAccessTraceRatePoint]
    @State private var hoverDate: Date?
    @State private var hoverLocation: CGPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading("请求读写速率", subtitle: "最近 5 秒平均值 · 折线")
            Chart(points) { point in
                LineMark(
                    x: .value(L10n.text("时间"), point.timestamp),
                    y: .value(L10n.text("读取"), point.readBytesPerSecond),
                    series: .value(L10n.text("系列"), "read")
                )
                .foregroundStyle(Color.teal)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.linear)
                LineMark(
                    x: .value(L10n.text("时间"), point.timestamp),
                    y: .value(L10n.text("写入"), point.writeBytesPerSecond),
                    series: .value(L10n.text("系列"), "write")
                )
                .foregroundStyle(Color.orange)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .interpolationMethod(.linear)
                if selectedPoint?.timestamp == point.timestamp {
                    RuleMark(x: .value(L10n.text("选中时间"), point.timestamp))
                        .foregroundStyle(.secondary.opacity(0.5))
                    PointMark(
                        x: .value(L10n.text("时间"), point.timestamp),
                        y: .value(L10n.text("读取"), point.readBytesPerSecond)
                    )
                    .foregroundStyle(Color.teal)
                    PointMark(
                        x: .value(L10n.text("时间"), point.timestamp),
                        y: .value(L10n.text("写入"), point.writeBytesPerSecond)
                    )
                    .foregroundStyle(Color.orange)
                }
            }
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let rate = value.as(Double.self) {
                            Text(ByteRateFormatter.rate(rate))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel(format: .dateTime.hour().minute().second())
                        .font(.caption2)
                }
            }
            .chartPlotStyle { $0.background(Color.secondary.opacity(0.035)) }
            .chartHoverSelection($hoverDate, location: $hoverLocation)
            .frame(height: 210)
            .overlay {
                if points.count < 2 {
                    ContentUnavailableView(
                        L10n.text("当前没有观察到读写请求"),
                        systemImage: "waveform.path.ecg"
                    )
                    .controlSize(.small)
                }
            }
            .overlay {
                if let point = selectedPoint, let hoverLocation {
                    TraceChartTooltip(point: point, pointer: hoverLocation)
                }
            }
        }
    }

    private var selectedPoint: FileAccessTraceRatePoint? {
        guard let hoverDate else { return nil }
        return points.min {
            abs($0.timestamp.timeIntervalSince(hoverDate))
                < abs($1.timestamp.timeIntervalSince(hoverDate))
        }
    }
}

private struct TraceChartTooltip: View {
    let point: FileAccessTraceRatePoint
    let pointer: CGPoint

    var body: some View {
        GeometryReader { geometry in
            let size = CGSize(width: 142, height: 74)
            let proposedX = pointer.x + size.width + 12 < geometry.size.width
                ? pointer.x + size.width / 2 + 10
                : pointer.x - size.width / 2 - 10
            let x = min(max(size.width / 2 + 4, proposedX), geometry.size.width - size.width / 2 - 4)
            let proposedY = pointer.y > size.height + 14
                ? pointer.y - size.height / 2 - 10
                : pointer.y + size.height / 2 + 10
            let y = min(max(size.height / 2 + 4, proposedY), geometry.size.height - size.height / 2 - 4)
            VStack(alignment: .leading, spacing: 5) {
                Text(point.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption.weight(.semibold))
                tooltipRow("读取", point.readBytesPerSecond, .teal)
                tooltipRow("写入", point.writeBytesPerSecond, .orange)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: size.width, height: size.height, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            .position(x: x, y: y)
        }
        .allowsHitTesting(false)
    }

    private func tooltipRow(_ title: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(L10n.text(title)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(ByteRateFormatter.rate(value)).monospacedDigit()
        }
        .font(.caption)
    }
}

private struct TraceFileRow: Identifiable, Equatable {
    let id: String
    let name: String
    let rawPath: String
    let displayPath: String
    let directory: String
    let fileExtension: String
    let read: UInt64
    let write: UInt64
    let total: UInt64

    init(_ item: FileAccessTraceFileSummary) {
        let url = URL(fileURLWithPath: item.path)
        id = item.id
        name = url.lastPathComponent
        rawPath = item.path
        displayPath = privateTracePath(item.path)
        directory = privateTracePath(url.deletingLastPathComponent().path)
        fileExtension = url.pathExtension.lowercased()
        read = item.requestedReadBytes
        write = item.requestedWriteBytes
        total = read.addingReportingOverflow(write).overflow ? UInt64.max : read + write
    }
}

private struct TraceProcessRow: Identifiable, Equatable {
    let id: String
    let name: String
    let pid: Int32
    let read: UInt64
    let write: UInt64
    let total: UInt64

    init(_ item: FileAccessTraceProcessSummary) {
        id = item.id
        name = item.identity.displayName
        pid = item.identity.pid
        read = item.requestedReadBytes
        write = item.requestedWriteBytes
        total = read.addingReportingOverflow(write).overflow ? UInt64.max : read + write
    }
}

private struct TraceFileTable: View {
    let items: [FileAccessTraceFileSummary]
    @State private var rows: [TraceFileRow] = []
    @State private var sortOrder = [
        KeyPathComparator(\TraceFileRow.write, order: .reverse)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tableHeading("最活跃文件", count: rows.count, symbol: "doc.text.magnifyingglass")
            Divider()
            Table(rows, sortOrder: $sortOrder) {
                TableColumn(L10n.text("文件"), value: \.name) { row in
                    TraceFileIdentityCell(row: row)
                }
                .width(min: 220, ideal: 320)
                TableColumn(L10n.text("请求读取"), value: \.read) { row in
                    TraceTransferCell(value: row.read, color: .teal)
                }
                .width(min: 82, ideal: 98)
                TableColumn(L10n.text("请求写入"), value: \.write) { row in
                    TraceTransferCell(value: row.write, color: .orange)
                }
                .width(min: 82, ideal: 98)
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(
                        L10n.text("当前没有观察到读写请求"),
                        systemImage: "doc"
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
            rows = newValue.map(TraceFileRow.init).sorted(using: sortOrder)
        }
        .onChange(of: sortOrder) { _, newValue in
            rows.sort(using: newValue)
        }
    }
}

private struct TraceFileIdentityCell: View {
    let row: TraceFileRow
    @State private var isHovered = false
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: fileSymbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(fileColor)
                .frame(width: 30, height: 30)
                .background(fileColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(row.directory)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            Button(action: copyPath) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered || copied ? 1 : 0.48)
            .help(L10n.text("复制路径"))
            .accessibilityLabel(L10n.text("复制路径"))
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(row.displayPath)
        .contextMenu {
            Button(action: copyPath) {
                Label(L10n.text("复制路径"), systemImage: "doc.on.doc")
            }
        }
        .onDisappear {
            resetTask?.cancel()
        }
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.rawPath, forType: .string)
        copied = true
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    private var fileSymbol: String {
        switch row.fileExtension {
        case "sqlite", "sqlite3", "db": "cylinder.split.1x2"
        case "json", "jsonl", "log": "doc.text"
        case "wal", "shm": "arrow.triangle.2.circlepath"
        default: "doc"
        }
    }

    private var fileColor: Color {
        switch row.fileExtension {
        case "sqlite", "sqlite3", "db", "wal", "shm": .indigo
        case "json", "jsonl", "log": .blue
        default: .secondary
        }
    }
}

private struct TraceTransferCell: View {
    let value: UInt64
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color.opacity(value == 0 ? 0.18 : 0.82))
                .frame(width: 3, height: 18)
            Text(ByteRateFormatter.bytes(value))
                .font(.callout.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
    }
}

private struct TraceProcessTable: View {
    let items: [FileAccessTraceProcessSummary]
    @State private var rows: [TraceProcessRow] = []
    @State private var sortOrder = [
        KeyPathComparator(\TraceProcessRow.write, order: .reverse)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tableHeading("访问应用", count: rows.count, symbol: "square.stack.3d.up")
            Divider()
            Table(rows, sortOrder: $sortOrder) {
                TableColumn(L10n.text("应用或进程"), value: \.name) { row in
                    HStack(spacing: 8) {
                        TraceProcessIcon(pid: row.pid)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name).lineLimit(1)
                            Text(L10n.format("进程 ID %d", row.pid))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .width(min: 130, ideal: 190)
                TableColumn(L10n.text("请求读取"), value: \.read) { row in
                    Text(ByteRateFormatter.bytes(row.read)).monospacedDigit()
                }
                .width(min: 78, ideal: 96)
                TableColumn(L10n.text("请求写入"), value: \.write) { row in
                    Text(ByteRateFormatter.bytes(row.write)).monospacedDigit()
                }
                .width(min: 78, ideal: 96)
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(
                        L10n.text("当前没有观察到访问应用"),
                        systemImage: "app.dashed"
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
            rows = newValue.map(TraceProcessRow.init).sorted(using: sortOrder)
        }
        .onChange(of: sortOrder) { _, newValue in
            rows.sort(using: newValue)
        }
    }
}

private struct TraceProcessIcon: View {
    let pid: Int32
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
            image = NSRunningApplication(processIdentifier: pid_t(pid))?.icon
        }
        .accessibilityHidden(true)
    }
}

@MainActor
private func tableHeading(_ title: String, count: Int, symbol: String) -> some View {
    HStack(spacing: 8) {
        Image(systemName: symbol).foregroundStyle(.secondary)
        Text(L10n.text(title)).font(.headline)
        Spacer()
        Text(count.formatted())
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 12)
    .frame(height: 42)
}

private func privateTracePath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    guard path == home || path.hasPrefix(home + "/") else { return path }
    return "~" + path.dropFirst(home.count)
}
