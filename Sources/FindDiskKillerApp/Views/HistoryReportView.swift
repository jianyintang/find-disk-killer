import FindDiskKillerCore
import SwiftUI

struct HistoryReportView: View {
    let history: HistoryModel
    let openDataSettings: () -> Void
    @State private var range: HistoryRetention = .sevenDays
    @State private var trendMetric: HistoryTrendMetric = .disk
    @State private var exportError: String?

    init(history: HistoryModel, openDataSettings: @escaping () -> Void = {}) {
        self.history = history
        self.openDataSettings = openDataSettings
    }

    var body: some View {
        VStack(spacing: 0) {
            reportToolbar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            .buttonStyle(AppIconButtonStyle(size: 30))
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
                .buttonStyle(AppActionButtonStyle(kind: .primary))
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
        HistoryReportLoadingContent()
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
            Button(action: openDataSettings) {
                Label(L10n.text("打开数据设置"), systemImage: "gear")
            }
            .buttonStyle(AppActionButtonStyle(kind: .primary))
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
            value: report.summary.diskObservedSeconds > 0
                ? ByteRateFormatter.bytes(report.summary.diskWriteBytes)
                : L10n.text("不可用"),
            symbol: "arrow.down.to.line",
            color: InstrumentDesign.ColorRole.diskWrite
        )
    }

    private func readMetric(_ report: HistoryReport) -> some View {
        ReportMetric(
            title: L10n.text("物理读取"),
            value: report.summary.diskObservedSeconds > 0
                ? ByteRateFormatter.bytes(report.summary.diskReadBytes)
                : L10n.text("不可用"),
            symbol: "arrow.up.from.line",
            color: InstrumentDesign.ColorRole.diskRead
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
            value: report.summary.networkObservedSeconds > 0
                ? ByteRateFormatter.bytes(
                    report.summary.networkReceiveBytes + report.summary.networkSendBytes
                )
                : L10n.text("不可用"),
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
                Text(trendMetric.chartTitle)
                    .font(.headline)
                Spacer()
                Picker(L10n.text("趋势指标"), selection: $trendMetric) {
                    ForEach(HistoryTrendMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            }

            HistoryTrendChart(
                points: report.trend,
                metric: trendMetric,
                coverage: metricCoverage(report.summary),
                reportDomain: report.start...report.end
            )
            .id("\(report.start.timeIntervalSince1970)-\(report.end.timeIntervalSince1970)-\(trendMetric.rawValue)")
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

    private func insightText(_ report: HistoryReport) -> String {
        guard report.summary.diskCoverage >= 0.7 else {
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

    private func metricCoverage(_ summary: HistorySummary) -> Double {
        switch trendMetric {
        case .disk: summary.diskCoverage
        case .cpu: summary.cpuCoverage
        case .network: summary.networkCoverage
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
        .accessibilityValue(L10n.percent(clampedCoverage))
    }

    private func export(_ report: HistoryReport, as format: HistoryExportFormat) {
        Task {
            do {
                try await HistoryReportExporter.presentSavePanel(for: report, format: format)
            } catch {
                exportError = L10n.errorDescription(error)
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

struct HistoryReportNavigationPlaceholder: View {
    var body: some View {
        VStack(spacing: 0) {
            HistoryReportLoadingToolbar()
            Divider()
            HistoryReportLoadingContent()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct HistoryReportLoadingToolbar: View {
    var body: some View {
        HStack(spacing: 16) {
            Text(L10n.text("分析周期"))
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker(
                L10n.text("分析周期"),
                selection: Binding.constant(HistoryRetention.sevenDays)
            ) {
                ForEach(HistoryRetention.allCases) { option in
                    Text(option.localizedTitle).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            Spacer()

            Label(L10n.text("历史保存正常"), systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {} label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 22)
        .frame(height: 54)
    }
}

private struct HistoryReportLoadingContent: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)

                Divider()

                metricBand
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)

                Divider()

                trendSection
                    .padding(24)

                Divider()

                insightSection
                    .padding(24)

                Divider()

                applicationSection
                    .padding(24)
            }
        }
        .redacted(reason: .placeholder)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text(HistoryRetention.sevenDays.localizedAnalysisTitle)
                    .font(.title2.weight(.semibold))
                Text("2026/07/21 – 2026/07/28")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                Label(L10n.format("数据覆盖 %.0f%%", 100.0), systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                ProgressView(value: 1)
                    .progressViewStyle(.linear)
                    .frame(width: 132)
            }
        }
    }

    private var metricBand: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                metric(L10n.text("物理写入"), "000 GB")
                metricDivider
                metric(L10n.text("物理读取"), "000 GB")
                metricDivider
                metric(L10n.text("平均 CPU"), "00.0%")
                metricDivider
                metric(L10n.text("网络传输"), "000 GB")
            }
            .frame(minWidth: 680)

            Grid(horizontalSpacing: 32, verticalSpacing: 20) {
                GridRow {
                    metric(L10n.text("物理写入"), "000 GB")
                    metric(L10n.text("物理读取"), "000 GB")
                }
                GridRow {
                    metric(L10n.text("平均 CPU"), "00.0%")
                    metric(L10n.text("网络传输"), "000 GB")
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption)
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metricDivider: some View {
        Divider().frame(height: 48).padding(.horizontal, 20)
    }

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.text("磁盘活动趋势"))
                    .font(.headline)
                Spacer()
                Picker(
                    L10n.text("趋势指标"),
                    selection: Binding.constant(HistoryTrendMetric.disk)
                ) {
                    ForEach(HistoryTrendMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            }

            VStack(spacing: 10) {
                chartPlaceholder
                timelinePlaceholder
            }
        }
    }

    private var chartPlaceholder: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { _ in
                    Divider()
                    Spacer()
                }
            }

            HStack(spacing: 14) {
                Label(L10n.text("写入"), systemImage: "circle.fill")
                Label(L10n.text("读取"), systemImage: "circle.fill")
            }
            .font(.caption)
            .padding(.leading, 72)
            .padding(.top, 4)
        }
        .frame(height: 270)
    }

    private var timelinePlaceholder: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 5)
                .fill(.quaternary)
                .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 120, height: 26)
        }
        .padding(.leading, 72)
        .padding(.trailing, 8)
        .frame(height: 30)
        .padding(.top, 7)
    }

    private var insightSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("周期观察"))
                .font(.headline)
            Label(
                L10n.text("当前周期数据覆盖不足 70%，暂不生成与上一周期的比较结论。"),
                systemImage: "scope"
            )
            .foregroundStyle(.secondary)
        }
    }

    private var applicationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("主要应用"))
                .font(.headline)
            HistoryApplicationTable(applications: [], isLoading: true)
        }
    }
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
