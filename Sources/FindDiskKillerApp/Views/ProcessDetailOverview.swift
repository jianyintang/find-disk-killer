import AppKit
import FindDiskKillerCore
import SwiftUI

struct ProcessDetailOverview: View {
    let process: ProcessActivity
    let points: [ProcessMetricPoint]
    let chartsReady: Bool
    let isProcessAvailable: Bool
    let systemMemory: SystemMemorySnapshot?

    @State private var selectedChart: ProcessChartKind = .cpu

    private let metricColumns = Array(
        repeating: GridItem(.flexible(minimum: 0), spacing: 10),
        count: 3
    )

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: metricColumns, spacing: 10) {
                    cpuMetric
                    totalWriteMetric
                    currentWriteMetric
                    peakWriteMetric
                    networkMetric
                    memoryMetric
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        chartPanel
                            .frame(minWidth: 470)
                        ProcessGroupInspector(
                            process: process,
                            points: points,
                            isProcessAvailable: isProcessAvailable
                        )
                        .frame(width: 210)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        chartPanel
                        ProcessGroupInspector(
                            process: process,
                            points: points,
                            isProcessAvailable: isProcessAvailable
                        )
                    }
                }

                ProcessEvidenceRail(process: process)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
    }

    private var cpuMetric: some View {
        GlassMetricTile(
            title: "CPU · 最近 5 秒",
            symbol: "cpu",
            accent: InstrumentDesign.ColorRole.cpu,
            accessibilitySummary: L10n.format(
                "CPU 当前 %@",
                PercentFormatter.cpu(process.currentCPUPercent)
            )
        ) {
            DataValue(
                value: L10n.decimal(process.currentCPUPercent, fractionDigits: 1),
                unit: "%",
                size: 32
            )
        } visualization: {
            MicroHistogram(
                values: recentPoints.map(\.cpuPercent),
                accent: InstrumentDesign.ColorRole.cpu,
                warningThreshold: 80
            )
        }
    }

    private var totalWriteMetric: some View {
        GlassMetricTile(
            title: "区间总写入",
            symbol: "externaldrive.badge.plus",
            accent: InstrumentDesign.ColorRole.diskWrite,
            accessibilitySummary: L10n.format(
                "区间总写入 %@",
                ByteRateFormatter.bytes(process.totalWriteBytes)
            )
        ) {
            formattedValue(ByteRateFormatter.bytes(process.totalWriteBytes))
        } visualization: {
            RecentWriteActivitySegments(values: recentPoints.map(\.writeBytesPerSecond))
        }
    }

    private var currentWriteMetric: some View {
        GlassMetricTile(
            title: "当前写入",
            symbol: "chart.xyaxis.line",
            accent: InstrumentDesign.ColorRole.diskWrite,
            accessibilitySummary: L10n.format(
                "磁盘读取当前 %@，写入当前 %@",
                ByteRateFormatter.rate(process.currentReadBytesPerSecond),
                ByteRateFormatter.rate(process.currentWriteBytesPerSecond)
            )
        ) {
            formattedValue(ByteRateFormatter.rate(process.currentWriteBytesPerSecond))
        } visualization: {
            VStack(spacing: 5) {
                DiskIOSparkline(
                    read: recentPoints.map(\.readBytesPerSecond),
                    write: recentPoints.map(\.writeBytesPerSecond),
                    capacity: 24
                )
                ProcessDiskLegend()
            }
        }
    }

    private var peakWriteMetric: some View {
        GlassMetricTile(
            title: "写入峰值",
            symbol: "waveform.path.ecg",
            accent: InstrumentDesign.ColorRole.diskWrite,
            accessibilitySummary: L10n.format(
                "写入峰值 %@",
                ByteRateFormatter.rate(process.peakWriteBytesPerSecond)
            )
        ) {
            formattedValue(ByteRateFormatter.rate(process.peakWriteBytesPerSecond))
        } visualization: {
            PeakWriteScale(
                current: process.currentWriteBytesPerSecond,
                peak: process.peakWriteBytesPerSecond
            )
        }
    }

    private var networkMetric: some View {
        let total = process.currentNetworkReceiveBytesPerSecond
            + process.currentNetworkSendBytesPerSecond
        return GlassMetricTile(
            title: "网络 · 最近 5 秒",
            symbol: "arrow.up.arrow.down",
            accent: InstrumentDesign.ColorRole.read,
            accessibilitySummary: process.isNetworkAvailable
                ? L10n.format(
                    "网络当前下载 %@，上传 %@",
                    ByteRateFormatter.rate(process.currentNetworkReceiveBytesPerSecond),
                    ByteRateFormatter.rate(process.currentNetworkSendBytesPerSecond)
                )
                : L10n.text("网络采样存在缺口")
        ) {
            process.isNetworkAvailable
                ? formattedValue(ByteRateFormatter.rate(total))
                : DataValue(value: L10n.text("采样缺口"), unit: nil, size: 24)
        } visualization: {
            BidirectionalNetworkBars(
                receive: recentPoints.map(\.networkReceiveBytesPerSecond),
                send: recentPoints.map(\.networkSendBytesPerSecond),
                capacity: 18
            )
        }
    }

    private var memoryMetric: some View {
        GlassMetricTile(
            title: "驻留内存",
            symbol: "memorychip",
            accent: InstrumentDesign.ColorRole.memory,
            accessibilitySummary: L10n.format(
                "当前已用 %@",
                ByteRateFormatter.bytes(process.currentMemoryBytes)
            )
        ) {
            formattedValue(ByteRateFormatter.bytes(process.currentMemoryBytes))
        } visualization: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    legendValue(
                        "进程",
                        ByteRateFormatter.bytes(process.currentMemoryBytes),
                        InstrumentDesign.ColorRole.memory
                    )
                    if let total = systemMemory?.totalBytes {
                        legendValue("总计", ByteRateFormatter.bytes(total), .secondary)
                    }
                }
                Spacer(minLength: 2)
                MemoryDonut(
                    used: process.currentMemoryBytes,
                    total: systemMemory?.totalBytes ?? 0
                )
                .frame(width: 54, height: 54)
            }
        }
    }

    private var chartPanel: some View {
        GlassSurface(padding: 14) {
            VStack(spacing: 12) {
                GlassSegmentedControl("详情视图", selection: $selectedChart) {
                    ForEach(ProcessChartKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }

                Group {
                    if chartsReady {
                        ProcessMetricChart(
                            points: points,
                            kind: selectedChart,
                            height: 242
                        )
                    } else {
                        ProcessChartSkeleton()
                            .frame(height: 242)
                    }
                }
            }
        }
    }

    private var recentPoints: [ProcessMetricPoint] {
        Array(points.suffix(24))
    }

    private func formattedValue(_ value: String) -> DataValue {
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        return DataValue(
            value: parts.first ?? value,
            unit: parts.count > 1 ? parts[1] : nil,
            size: 32
        )
    }

    private func legendValue(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color.opacity(0.76))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(L10n.text(title))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .monospacedDigit()
        }
        .font(.caption2)
    }
}

private struct ProcessDiskLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            legend("读取", InstrumentDesign.ColorRole.diskRead)
            legend("写入", InstrumentDesign.ColorRole.diskWrite)
            Spacer(minLength: 0)
        }
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(L10n.text(title))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct RecentWriteActivitySegments: View {
    let values: [Double?]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(buckets.enumerated()), id: \.offset) { _, value in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color(for: value))
                    .overlay {
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                    }
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.48),
                        value: value
                    )
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }

    private var buckets: [Double?] {
        let bucketCount = 10
        guard !values.isEmpty else { return Array(repeating: nil, count: bucketCount) }
        return (0..<bucketCount).map { bucket in
            let start = bucket * values.count / bucketCount
            let end = (bucket + 1) * values.count / bucketCount
            guard start < end else { return nil }
            return values[start..<end].compactMap { $0 }.max()
        }
    }

    private var maximum: Double {
        max(buckets.compactMap { $0 }.max() ?? 0, 1)
    }

    private func color(for value: Double?) -> Color {
        guard let value else { return Color.secondary.opacity(0.12) }
        let intensity = min(1, max(0.16, value / maximum))
        return InstrumentDesign.ColorRole.diskWrite.opacity(0.22 + intensity * 0.58)
    }
}

private struct PeakWriteScale: View {
    let current: Double
    let peak: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let shape = RoundedRectangle(cornerRadius: 3)
            ZStack(alignment: .leading) {
                shape.fill(Color.secondary.opacity(0.14))
                shape
                    .fill(InstrumentDesign.ColorRole.diskWrite.opacity(0.72))
                    .frame(width: geometry.size.width * currentFraction)
                Rectangle()
                    .fill(InstrumentDesign.ColorRole.diskWrite.opacity(0.92))
                    .frame(width: 1.5)
                    .offset(x: max(0, geometry.size.width - 1.5))
            }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.48),
                value: currentFraction
            )
        }
        .frame(height: 13)
        .accessibilityHidden(true)
    }

    private var currentFraction: Double {
        guard peak > 0 else { return 0 }
        return min(1, max(0, current / peak))
    }
}

private struct ProcessGroupInspector: View {
    let process: ProcessActivity
    let points: [ProcessMetricPoint]
    let isProcessAvailable: Bool

    var body: some View {
        GlassSurface(padding: 16) {
            VStack(alignment: .leading, spacing: 18) {
                Text(L10n.text("进程组"))
                    .font(.system(size: 17, weight: .medium))

                Label(
                    L10n.format("%d 个进程", process.memberCount),
                    systemImage: "person.2"
                )
                .font(.system(size: 13, weight: .medium))

                inspectorRow(
                    title: "状态",
                    value: isProcessAvailable ? "正在活动的应用" : "应用样本已结束",
                    color: isProcessAvailable
                        ? InstrumentDesign.ColorRole.healthy
                        : .secondary
                )

                inspectorRow(
                    title: "时间范围",
                    value: sampleWindow,
                    color: InstrumentDesign.ColorRole.cpu
                )

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 286, alignment: .topLeading)
        }
        .accessibilityElement(children: .combine)
    }

    private var sampleWindow: String {
        let duration: TimeInterval
        if let first = points.first?.timestamp, let last = points.last?.timestamp {
            duration = max(0, last.timeIntervalSince(first))
        } else {
            duration = 0
        }
        return "\(L10n.number(points.count)) · \(L10n.duration(seconds: duration))"
    }

    private func inspectorRow(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text(title))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 7) {
                Circle()
                    .fill(color.opacity(0.82))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(L10n.text(value))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(2)
            }
        }
    }
}

private struct ProcessEvidenceRail: View {
    let process: ProcessActivity

    var body: some View {
        GlassSurface(padding: 0) {
            HStack(spacing: 14) {
                EvidenceLabel(
                    text: "应用 I/O 当前为全盘合计",
                    symbol: "checkmark.circle.fill",
                    color: InstrumentDesign.ColorRole.healthy
                )
                Divider().frame(height: 26)
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(process.executablePath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button(action: copyPath) {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(.plain)
                .glassSurface(cornerRadius: 6, padding: 3)
                .help(L10n.text("复制路径"))
                .accessibilityLabel(L10n.text("复制路径"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(process.executablePath, forType: .string)
    }
}

private struct ProcessChartSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ForEach(0..<4, id: \.self) { _ in
                Divider().opacity(0.35)
                Spacer()
            }
        }
        .background(Color.secondary.opacity(0.035))
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}
