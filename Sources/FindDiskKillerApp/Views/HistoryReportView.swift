import Charts
import FindDiskKillerCore
import SwiftUI

struct HistoryReportView: View {
    private enum TrendMetric: String, CaseIterable, Identifiable {
        case disk
        case cpu
        case network

        var id: String { rawValue }
        var title: String {
            switch self {
            case .disk: L10n.text("磁盘")
            case .cpu: "CPU"
            case .network: L10n.text("网络")
            }
        }
    }

    let history: HistoryModel
    @State private var range: HistoryRetention = .sevenDays
    @State private var selectedDate: Date?
    @State private var trendMetric: TrendMetric = .disk
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            reportToolbar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(L10n.text("历史分析"))
        .task(id: range) {
            await history.loadReport(range: range)
        }
        .alert(L10n.text("无法导出历史分析"), isPresented: exportErrorBinding) {
            Button(L10n.text("好"), role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private var reportToolbar: some View {
        HStack(spacing: 16) {
            Text(L10n.text("分析周期"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker(L10n.text("分析周期"), selection: $range) {
                ForEach(HistoryRetention.allCases) { option in
                    Text(option.localizedTitle).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            Spacer()

            storageStatus

            if case .loaded(let report) = history.reportState {
                Menu {
                    Button {
                        export(report, as: .pdf)
                    } label: {
                        Label(L10n.text("导出 PDF"), systemImage: "doc.richtext")
                    }
                    Button {
                        export(report, as: .csv)
                    } label: {
                        Label(L10n.text("导出 CSV"), systemImage: "tablecells")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .help(L10n.text("导出历史分析"))
                .accessibilityLabel(L10n.text("导出历史分析"))
            }

            Button {
                Task { await history.loadReport(range: range) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(L10n.text("刷新分析"))
            .accessibilityLabel(L10n.text("刷新分析"))
        }
        .padding(.horizontal, 22)
        .frame(height: 54)
    }

    @ViewBuilder
    private var content: some View {
        switch history.reportState {
        case .idle, .loading:
            loadingView
        case .failed(let message):
            ContentUnavailableView {
                Label(L10n.text("无法读取历史分析"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(L10n.text("重试")) {
                    Task { await history.loadReport(range: range) }
                }
            }
        case .loaded(let report):
            if report.trend.isEmpty {
                emptyView
            } else {
                reportContent(report)
            }
        }
    }

    private var loadingView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 28) {
                    ForEach(0..<4, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Metric label")
                            Text("000.0 GB").font(.title2.monospacedDigit())
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Rectangle().fill(.quaternary).frame(height: 260)
                ForEach(0..<5, id: \.self) { _ in
                    Rectangle().fill(.quaternary).frame(height: 36)
                }
            }
            .padding(24)
            .redacted(reason: .placeholder)
        }
        .accessibilityLabel(L10n.text("正在加载历史分析"))
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label(
                history.configuration.isEnabled
                    ? L10n.text("正在积累历史数据")
                    : L10n.text("尚未保存监测历史"),
                systemImage: "chart.xyaxis.line"
            )
        } description: {
            Text(history.configuration.isEnabled
                ? L10n.text("完成第一个分钟汇总后，这里会出现趋势和应用排名。")
                : L10n.text("在设置中开启后，聚合数据将每分钟保存一次且只留在本机。"))
        } actions: {
            SettingsLink {
                Label(L10n.text("打开数据设置"), systemImage: "gear")
            }
        }
    }

    private func reportContent(_ report: HistoryReport) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                reportHeader(report)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)

                Divider()

                metricBand(report)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)

                Divider()

                trendSection(report)
                    .padding(24)

                Divider()

                insightSection(report)
                    .padding(24)

                Divider()

                applicationSection(report)
                    .padding(24)
            }
        }
    }

    private func reportHeader(_ report: HistoryReport) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text(range.localizedAnalysisTitle)
                    .font(.title2.weight(.semibold))
                Text(L10n.date(report.start, date: .abbreviated, time: .omitted)
                    + " – "
                    + L10n.date(report.end, date: .abbreviated, time: .omitted))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            coverageStatus(report.summary.coverage)
        }
    }

    private func metricBand(_ report: HistoryReport) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                writeMetric(report)
                metricDivider
                readMetric(report)
                metricDivider
                cpuMetric(report)
                metricDivider
                networkMetric(report)
            }
            .frame(minWidth: 680)

            Grid(horizontalSpacing: 32, verticalSpacing: 20) {
                GridRow {
                    writeMetric(report)
                    readMetric(report)
                }
                GridRow {
                    cpuMetric(report)
                    networkMetric(report)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func writeMetric(_ report: HistoryReport) -> some View {
        ReportMetric(
            title: L10n.text("物理写入"),
            value: ByteRateFormatter.bytes(report.summary.diskWriteBytes),
            symbol: "arrow.down.to.line",
            color: .blue
        )
    }

    private func readMetric(_ report: HistoryReport) -> some View {
        ReportMetric(
            title: L10n.text("物理读取"),
            value: ByteRateFormatter.bytes(report.summary.diskReadBytes),
            symbol: "arrow.up.from.line",
            color: .green
        )
    }

    private func cpuMetric(_ report: HistoryReport) -> some View {
        ReportMetric(
            title: L10n.text("平均 CPU"),
            value: report.summary.averageCPUPercent.map(PercentFormatter.cpu) ?? L10n.text("不可用"),
            symbol: "cpu",
            color: .orange
        )
    }

    private func networkMetric(_ report: HistoryReport) -> some View {
        ReportMetric(
            title: L10n.text("网络传输"),
            value: ByteRateFormatter.bytes(
                report.summary.networkReceiveBytes + report.summary.networkSendBytes
            ),
            symbol: "arrow.up.arrow.down",
            color: .teal
        )
    }

    private var metricDivider: some View {
        Divider().frame(height: 48).padding(.horizontal, 20)
    }

    private func trendSection(_ report: HistoryReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(trendTitle)
                    .font(.headline)
                Spacer()
                Picker(L10n.text("趋势指标"), selection: $trendMetric) {
                    ForEach(TrendMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            }

            Chart {
                ForEach(chartSeries(report)) { value in
                    LineMark(
                        x: .value(L10n.text("时间"), value.timestamp),
                        y: .value(value.series, value.value),
                        series: .value(L10n.text("连续区间"), value.series + value.segment)
                    )
                    .foregroundStyle(by: .value(L10n.text("指标"), value.series))
                    .interpolationMethod(.monotone)
                }

                if let selectedPoint = selectedTrendPoint(in: report) {
                    RuleMark(x: .value(L10n.text("选定时间"), selectedPoint.timestamp))
                        .foregroundStyle(.secondary.opacity(0.7))
                        .annotation(position: .top, alignment: .leading) {
                            trendTooltip(selectedPoint)
                        }
                }
            }
            .chartForegroundStyleScale(domain: chartStyleDomain, range: chartStyleRange)
            .chartLegend(position: .top, alignment: .leading, spacing: 14)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let measurement = value.as(Double.self) {
                            Text(trendMetric == .cpu
                                ? PercentFormatter.cpu(measurement)
                                : ByteRateFormatter.rate(measurement))
                        }
                    }
                }
            }
            .chartXSelection(value: $selectedDate)
            .frame(height: 270)
            .accessibilityLabel(trendTitle)
            .accessibilityValue(trendAccessibilitySummary(report))

            HStack(spacing: 7) {
                Image(systemName: "circle.dashed")
                Text(L10n.text("缺失时段会断开显示，不会按零值补齐。"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func insightSection(_ report: HistoryReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("周期观察"))
                .font(.headline)
            Label(insightText(report), systemImage: "scope")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func applicationSection(_ report: HistoryReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("主要应用"))
                    .font(.headline)
            }

            if report.applications.isEmpty {
                Text(history.configuration.savesApplicationActivity
                    ? L10n.text("这个周期还没有应用级活动。")
                    : L10n.text("当前仅保存整机与设备聚合。"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                HistoryApplicationTable(applications: report.applications)
            }
        }
    }

    private var storageStatus: some View {
        Label(storageStatusText, systemImage: storageStatusSymbol)
            .font(.caption)
            .foregroundStyle(storageStatusColor)
    }

    private var storageStatusText: String {
        guard history.configuration.isEnabled else {
            return L10n.text("历史保存已关闭")
        }
        return switch history.storageInfo.state {
        case .normal: L10n.text("历史保存正常")
        case .nearingLimit: L10n.text("接近空间上限")
        case .optimizing: L10n.text("正在优化历史")
        case .compacted: L10n.text("部分明细已精简")
        case .paused: L10n.text("已暂停历史保存")
        case .unavailable: L10n.text("历史数据库不可用")
        }
    }

    private var storageStatusSymbol: String {
        guard history.configuration.isEnabled else { return "pause.circle" }
        return switch history.storageInfo.state {
        case .normal: "checkmark.circle"
        case .nearingLimit: "externaldrive.badge.exclamationmark"
        case .optimizing: "arrow.triangle.2.circlepath"
        case .compacted: "rectangle.compress.vertical"
        case .paused, .unavailable: "exclamationmark.triangle"
        }
    }

    private var storageStatusColor: Color {
        guard history.configuration.isEnabled else { return .secondary }
        return switch history.storageInfo.state {
        case .normal: .secondary
        case .optimizing: .blue
        case .compacted, .nearingLimit: .orange
        case .paused, .unavailable: .red
        }
    }

    private func rate(_ bytes: UInt64, duration: TimeInterval) -> Double {
        Double(bytes) / max(1, duration)
    }

    private func insightText(_ report: HistoryReport) -> String {
        guard report.summary.coverage >= 0.7 else {
            return L10n.text("当前周期数据覆盖不足 70%，暂不生成与上一周期的比较结论。")
        }
        guard let previous = report.previousPeriodDiskWriteBytes, previous > 0 else {
            return L10n.text("上一周期数据不足；当前结论仅基于已覆盖时间，不会用零值补齐缺口。")
        }
        let change = (Double(report.summary.diskWriteBytes) / Double(previous) - 1) * 100
        if abs(change) < 5 {
            return L10n.text("物理写入与上一周期基本持平。")
        }
        return change > 0
            ? L10n.format("物理写入较上一周期增加 %.0f%%。", change)
            : L10n.format("物理写入较上一周期减少 %.0f%%。", abs(change))
    }

    private var trendTitle: String {
        switch trendMetric {
        case .disk: L10n.text("磁盘活动趋势")
        case .cpu: L10n.text("CPU 活动趋势")
        case .network: L10n.text("网络活动趋势")
        }
    }

    private var chartStyleDomain: [String] {
        switch trendMetric {
        case .disk: [L10n.text("写入"), L10n.text("读取")]
        case .cpu: [L10n.text("平均 CPU")]
        case .network: [L10n.text("接收"), L10n.text("发送")]
        }
    }

    private var chartStyleRange: [Color] {
        switch trendMetric {
        case .disk: [.blue, .green]
        case .cpu: [.orange]
        case .network: [.teal, .indigo]
        }
    }

    private func chartSeries(_ report: HistoryReport) -> [HistoryChartValue] {
        var values: [HistoryChartValue] = []
        var segment = 0
        var previous: HistoryTrendPoint?
        var cpuSeriesInterrupted = false
        for point in report.trend {
            if let previous {
                let expectedStep = max(previous.duration, point.duration)
                if point.timestamp.timeIntervalSince(previous.timestamp) > expectedStep * 1.8 {
                    segment += 1
                }
            }
            switch trendMetric {
            case .disk:
                let segmentID = "-\(segment)"
                values.append(.init(timestamp: point.timestamp, series: L10n.text("写入"), segment: segmentID, value: rate(point.diskWriteBytes, duration: point.duration)))
                values.append(.init(timestamp: point.timestamp, series: L10n.text("读取"), segment: segmentID, value: rate(point.diskReadBytes, duration: point.duration)))
            case .cpu:
                if let cpu = point.averageCPUPercent {
                    if cpuSeriesInterrupted {
                        segment += 1
                        cpuSeriesInterrupted = false
                    }
                    let segmentID = "-\(segment)"
                    values.append(.init(timestamp: point.timestamp, series: L10n.text("平均 CPU"), segment: segmentID, value: cpu))
                } else if !values.isEmpty {
                    cpuSeriesInterrupted = true
                }
            case .network:
                let segmentID = "-\(segment)"
                values.append(.init(timestamp: point.timestamp, series: L10n.text("接收"), segment: segmentID, value: rate(point.networkReceiveBytes, duration: point.duration)))
                values.append(.init(timestamp: point.timestamp, series: L10n.text("发送"), segment: segmentID, value: rate(point.networkSendBytes, duration: point.duration)))
            }
            previous = point
        }
        return values
    }

    private func selectedTrendPoint(in report: HistoryReport) -> HistoryTrendPoint? {
        guard let selectedDate else { return nil }
        return report.trend.min { lhs, rhs in
            abs(lhs.timestamp.timeIntervalSince(selectedDate))
                < abs(rhs.timestamp.timeIntervalSince(selectedDate))
        }
    }

    private func trendTooltip(_ point: HistoryTrendPoint) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.date(point.timestamp, date: .abbreviated, time: .shortened))
                .font(.caption.weight(.semibold))

            switch trendMetric {
            case .disk:
                tooltipValue(
                    L10n.text("写入"),
                    ByteRateFormatter.rate(rate(point.diskWriteBytes, duration: point.duration)),
                    color: .blue
                )
                tooltipValue(
                    L10n.text("读取"),
                    ByteRateFormatter.rate(rate(point.diskReadBytes, duration: point.duration)),
                    color: .green
                )
            case .cpu:
                tooltipValue(
                    L10n.text("平均 CPU"),
                    point.averageCPUPercent.map(PercentFormatter.cpu) ?? L10n.text("不可用"),
                    color: .orange
                )
                tooltipValue(
                    L10n.text("峰值 CPU"),
                    point.peakCPUPercent.map(PercentFormatter.cpu) ?? L10n.text("不可用"),
                    color: .orange.opacity(0.7)
                )
            case .network:
                tooltipValue(
                    L10n.text("接收"),
                    ByteRateFormatter.rate(rate(point.networkReceiveBytes, duration: point.duration)),
                    color: .teal
                )
                tooltipValue(
                    L10n.text("发送"),
                    ByteRateFormatter.rate(rate(point.networkSendBytes, duration: point.duration)),
                    color: .indigo
                )
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityHidden(true)
    }

    private func tooltipValue(_ title: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.caption)
        .frame(minWidth: 150)
    }

    private func trendAccessibilitySummary(_ report: HistoryReport) -> String {
        if let selectedPoint = selectedTrendPoint(in: report) {
            return [
                L10n.date(selectedPoint.timestamp, date: .abbreviated, time: .shortened),
                trendPointSummary(selectedPoint)
            ].joined(separator: ", ")
        }
        return L10n.format(
            "数据覆盖 %.0f%%，共 %d 个数据点",
            report.summary.coverage * 100,
            report.trend.count
        )
    }

    private func trendPointSummary(_ point: HistoryTrendPoint) -> String {
        switch trendMetric {
        case .disk:
            return [
                "\(L10n.text("写入")) \(ByteRateFormatter.rate(rate(point.diskWriteBytes, duration: point.duration)))",
                "\(L10n.text("读取")) \(ByteRateFormatter.rate(rate(point.diskReadBytes, duration: point.duration)))"
            ].joined(separator: ", ")
        case .cpu:
            return [
                "\(L10n.text("平均 CPU")) \(point.averageCPUPercent.map(PercentFormatter.cpu) ?? L10n.text("不可用"))",
                "\(L10n.text("峰值 CPU")) \(point.peakCPUPercent.map(PercentFormatter.cpu) ?? L10n.text("不可用"))"
            ].joined(separator: ", ")
        case .network:
            return [
                "\(L10n.text("接收")) \(ByteRateFormatter.rate(rate(point.networkReceiveBytes, duration: point.duration)))",
                "\(L10n.text("发送")) \(ByteRateFormatter.rate(rate(point.networkSendBytes, duration: point.duration)))"
            ].joined(separator: ", ")
        }
    }

    private func coverageStatus(_ coverage: Double) -> some View {
        let clampedCoverage = min(max(coverage, 0), 1)
        return VStack(alignment: .trailing, spacing: 5) {
            Label(
                L10n.format("数据覆盖 %.0f%%", coverage * 100),
                systemImage: coverage >= 0.8 ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(coverage >= 0.8 ? Color.green : Color.orange)
            ProgressView(value: clampedCoverage)
                .progressViewStyle(.linear)
                .tint(coverage >= 0.8 ? .green : .orange)
                .frame(width: 132)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("数据覆盖"))
        .accessibilityValue(clampedCoverage.formatted(.percent.precision(.fractionLength(0))))
    }

    private func export(_ report: HistoryReport, as format: HistoryExportFormat) {
        Task {
            do {
                try await HistoryReportExporter.presentSavePanel(for: report, format: format)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private var exportErrorBinding: Binding<Bool> {
        Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )
    }
}

private struct HistoryChartValue: Identifiable {
    let timestamp: Date
    let series: String
    let segment: String
    let value: Double

    var id: String { "\(timestamp.timeIntervalSince1970)-\(series)-\(segment)" }
}

private struct ReportMetric: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(color)
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
