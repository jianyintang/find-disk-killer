import Charts
import FindDiskKillerCore
import SwiftUI

struct MonitorChart: View {
    let points: [ThroughputPoint]
    var height: CGFloat = 210
    @State private var hoverDate: Date?
    @State private var hoverLocation: CGPoint?

    var body: some View {
        let selectedTimestamp = selectedPoint?.timestamp
        Chart(points) { point in
            if let read = point.readBytesPerSecond {
                LineMark(
                    x: .value(L10n.text("时间"), point.timestamp),
                    y: .value(L10n.text("读取"), read),
                    series: .value(L10n.text("系列"), "read-\(point.segment)")
                )
                .foregroundStyle(Color.teal)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.linear)
            }

            if let write = point.writeBytesPerSecond {
                LineMark(
                    x: .value(L10n.text("时间"), point.timestamp),
                    y: .value(L10n.text("写入"), write),
                    series: .value(L10n.text("系列"), "write-\(point.segment)")
                )
                .foregroundStyle(Color.orange)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .interpolationMethod(.linear)
            }

            if selectedTimestamp == point.timestamp {
                RuleMark(x: .value(L10n.text("选中时间"), point.timestamp))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                if let read = point.readBytesPerSecond {
                    PointMark(x: .value(L10n.text("时间"), point.timestamp), y: .value(L10n.text("读取"), read))
                        .foregroundStyle(Color.teal)
                }
                if let write = point.writeBytesPerSecond {
                    PointMark(x: .value(L10n.text("时间"), point.timestamp), y: .value(L10n.text("写入"), write))
                        .foregroundStyle(Color.orange)
                }
            }
        }
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.quaternary)
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
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.quaternary)
                AxisValueLabel(format: .dateTime.hour().minute().second())
                    .font(.caption2)
            }
        }
        .chartPlotStyle { plotArea in
            plotArea.background(Color.secondary.opacity(0.035))
        }
        .chartHoverSelection($hoverDate, location: $hoverLocation)
        .frame(height: height)
        .accessibilityLabel(L10n.text("磁盘吞吐趋势"))
        .accessibilityValue(accessibilitySummary)
        .overlay {
            if points.count < 2 {
                ContentUnavailableView(
                    L10n.text("正在收集磁盘样本"),
                    systemImage: "waveform.path.ecg"
                )
                .controlSize(.small)
            }
        }
        .overlay {
            if let point = selectedPoint, let hoverLocation {
                FollowingChartTooltip(
                    location: hoverLocation,
                    date: point.timestamp,
                    rows: [
                        (L10n.text("读取"), rateOrUnavailable(point.readBytesPerSecond), .teal),
                        (L10n.text("写入"), rateOrUnavailable(point.writeBytesPerSecond), .orange)
                    ]
                )
            }
        }
    }

    private var accessibilitySummary: String {
        guard let latest = points.last,
              let read = latest.readBytesPerSecond,
              let write = latest.writeBytesPerSecond
        else { return L10n.text("当前采样存在缺口") }
        return L10n.format(
            "当前读取 %@，写入 %@",
            ByteRateFormatter.rate(read),
            ByteRateFormatter.rate(write)
        )
    }

    private var selectedPoint: ThroughputPoint? {
        nearestPoint(points, to: hoverDate, timestamp: \.timestamp)
    }
}

struct SystemCPUChart: View {
    let points: [SystemResourcePoint]
    var height: CGFloat = 210
    @State private var hoverDate: Date?
    @State private var hoverLocation: CGPoint?

    var body: some View {
        let selectedTimestamp = selectedPoint?.timestamp
        Chart(points) { point in
            if let cpu = point.cpuPercent {
                LineMark(
                    x: .value(L10n.text("时间"), point.timestamp),
                    y: .value("CPU", cpu),
                    series: .value(L10n.text("系列"), "cpu-\(point.cpuSegment)")
                )
                .foregroundStyle(Color.blue)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.linear)
            }
            if selectedTimestamp == point.timestamp {
                RuleMark(x: .value(L10n.text("选中时间"), point.timestamp))
                    .foregroundStyle(.secondary.opacity(0.55))
                if let cpu = point.cpuPercent {
                    PointMark(x: .value(L10n.text("时间"), point.timestamp), y: .value("CPU", cpu))
                        .foregroundStyle(Color.blue)
                }
            }
        }
        .chartLegend(.hidden)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let percent = value.as(Double.self) {
                        Text("\(Int(percent))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .resourceTimeAxis()
        .chartPlotStyle { $0.background(Color.secondary.opacity(0.035)) }
        .chartHoverSelection($hoverDate, location: $hoverLocation)
        .frame(height: height)
        .accessibilityLabel(L10n.text("系统 CPU 趋势"))
        .overlay { emptyState(points.count, title: L10n.text("正在收集 CPU 样本")) }
        .overlay {
            if let point = selectedPoint, let hoverLocation {
                FollowingChartTooltip(
                    location: hoverLocation,
                    date: point.timestamp,
                    rows: [("CPU", percentOrUnavailable(point.cpuPercent), .blue)]
                )
            }
        }
    }

    private var selectedPoint: SystemResourcePoint? {
        nearestPoint(points, to: hoverDate, timestamp: \.timestamp)
    }
}

struct SystemNetworkChart: View {
    let points: [SystemResourcePoint]
    var height: CGFloat = 210
    @State private var hoverDate: Date?
    @State private var hoverLocation: CGPoint?

    var body: some View {
        let selectedTimestamp = selectedPoint?.timestamp
        Chart(points) { point in
            if let receive = point.networkReceiveBytesPerSecond {
                LineMark(
                    x: .value(L10n.text("时间"), point.timestamp),
                    y: .value(L10n.text("下载"), receive),
                    series: .value(L10n.text("系列"), "download-\(point.networkSegment)")
                )
                .foregroundStyle(Color.green)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.linear)
            }

            if let send = point.networkSendBytesPerSecond {
                LineMark(
                    x: .value(L10n.text("时间"), point.timestamp),
                    y: .value(L10n.text("上传"), send),
                    series: .value(L10n.text("系列"), "upload-\(point.networkSegment)")
                )
                .foregroundStyle(Color.indigo)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .interpolationMethod(.linear)
            }

            if selectedTimestamp == point.timestamp {
                RuleMark(x: .value(L10n.text("选中时间"), point.timestamp))
                    .foregroundStyle(.secondary.opacity(0.55))
                if let receive = point.networkReceiveBytesPerSecond {
                    PointMark(x: .value(L10n.text("时间"), point.timestamp), y: .value(L10n.text("下载"), receive))
                        .foregroundStyle(Color.green)
                }
                if let send = point.networkSendBytesPerSecond {
                    PointMark(x: .value(L10n.text("时间"), point.timestamp), y: .value(L10n.text("上传"), send))
                        .foregroundStyle(Color.indigo)
                }
            }
        }
        .chartLegend(.hidden)
        .resourceRateAxis()
        .resourceTimeAxis()
        .chartPlotStyle { $0.background(Color.secondary.opacity(0.035)) }
        .chartHoverSelection($hoverDate, location: $hoverLocation)
        .frame(height: height)
        .accessibilityLabel(L10n.text("系统网络趋势"))
        .overlay { emptyState(points.count, title: L10n.text("正在收集网络样本")) }
        .overlay {
            if let point = selectedPoint, let hoverLocation {
                FollowingChartTooltip(
                    location: hoverLocation,
                    date: point.timestamp,
                    rows: [
                        (L10n.text("下载"), rateOrUnavailable(point.networkReceiveBytesPerSecond), .green),
                        (L10n.text("上传"), rateOrUnavailable(point.networkSendBytesPerSecond), .indigo)
                    ]
                )
            }
        }
    }

    private var selectedPoint: SystemResourcePoint? {
        nearestPoint(points, to: hoverDate, timestamp: \.timestamp)
    }
}

enum ProcessChartKind: String, CaseIterable, Identifiable {
    case disk = "磁盘 I/O"
    case cpu = "CPU"
    case network = "网络"

    var id: String { rawValue }
    var title: String { L10n.text(rawValue) }
}

struct ProcessMetricChart: View {
    let points: [ProcessMetricPoint]
    let kind: ProcessChartKind
    var height: CGFloat = 150
    @State private var hoverDate: Date?
    @State private var hoverLocation: CGPoint?

    var body: some View {
        let selectedTimestamp = selectedPoint?.timestamp
        let timeLabel = L10n.text("时间")
        let seriesLabel = L10n.text("系列")
        let selectedTimeLabel = L10n.text("选中时间")
        let readLabel = L10n.text("读取")
        let writeLabel = L10n.text("写入")
        let downloadLabel = L10n.text("下载")
        let uploadLabel = L10n.text("上传")
        Chart(points) { point in
            switch kind {
            case .disk:
                LineMark(
                    x: .value(timeLabel, point.timestamp),
                    y: .value(readLabel, point.readBytesPerSecond),
                    series: .value(seriesLabel, "read")
                )
                .foregroundStyle(Color.teal)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.linear)
                LineMark(
                    x: .value(timeLabel, point.timestamp),
                    y: .value(writeLabel, point.writeBytesPerSecond),
                    series: .value(seriesLabel, "write")
                )
                .foregroundStyle(Color.orange)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .interpolationMethod(.linear)
            case .cpu:
                LineMark(
                    x: .value(timeLabel, point.timestamp),
                    y: .value("CPU", point.cpuPercent)
                )
                .foregroundStyle(Color.blue)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.linear)
            case .network:
                if let receive = point.networkReceiveBytesPerSecond {
                    LineMark(
                        x: .value(timeLabel, point.timestamp),
                        y: .value(downloadLabel, receive),
                        series: .value(seriesLabel, "download-\(point.networkSegment)")
                    )
                    .foregroundStyle(Color.green)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.linear)
                }
                if let send = point.networkSendBytesPerSecond {
                    LineMark(
                        x: .value(timeLabel, point.timestamp),
                        y: .value(uploadLabel, send),
                        series: .value(seriesLabel, "upload-\(point.networkSegment)")
                    )
                    .foregroundStyle(Color.indigo)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .interpolationMethod(.linear)
                }
            }

            if selectedTimestamp == point.timestamp {
                RuleMark(x: .value(selectedTimeLabel, point.timestamp))
                    .foregroundStyle(.secondary.opacity(0.55))
            }
        }
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(kind == .cpu ? PercentFormatter.cpu(number) : ByteRateFormatter.rate(number))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .resourceTimeAxis()
        .chartPlotStyle { $0.background(Color.secondary.opacity(0.035)) }
        .chartHoverSelection($hoverDate, location: $hoverLocation)
        .frame(height: height)
        .accessibilityLabel(L10n.format("应用%@趋势", kind.title))
        .overlay { emptyState(points.count, title: L10n.text("正在收集应用样本")) }
        .overlay {
            if let point = selectedPoint, let hoverLocation {
                FollowingChartTooltip(
                    location: hoverLocation,
                    date: point.timestamp,
                    rows: tooltipRows(for: point)
                )
            }
        }
    }

    private var selectedPoint: ProcessMetricPoint? {
        nearestPoint(points, to: hoverDate, timestamp: \.timestamp)
    }

    private func tooltipRows(for point: ProcessMetricPoint) -> [ChartTooltip.Row] {
        switch kind {
        case .disk:
            [
                (L10n.text("读取"), ByteRateFormatter.rate(point.readBytesPerSecond), .teal),
                (L10n.text("写入"), ByteRateFormatter.rate(point.writeBytesPerSecond), .orange)
            ]
        case .cpu:
            [("CPU", PercentFormatter.cpu(point.cpuPercent), .blue)]
        case .network:
            [
                (L10n.text("下载"), rateOrUnavailable(point.networkReceiveBytesPerSecond), .green),
                (L10n.text("上传"), rateOrUnavailable(point.networkSendBytesPerSecond), .indigo)
            ]
        }
    }
}

extension View {
    func resourceTimeAxis() -> some View {
        chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel(format: .dateTime.hour().minute().second())
                    .font(.caption2)
            }
        }
    }

    func resourceRateAxis() -> some View {
        chartYAxis {
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
    }

    func chartHoverSelection(
        _ selection: Binding<Date?>,
        location hoverLocation: Binding<CGPoint?>
    ) -> some View {
        chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(pointer):
                            guard let anchor = proxy.plotFrame else { return }
                            let frame = geometry[anchor]
                            guard frame.contains(pointer) else {
                                selection.wrappedValue = nil
                                hoverLocation.wrappedValue = nil
                                return
                            }
                            selection.wrappedValue = proxy.value(atX: pointer.x - frame.minX)
                            hoverLocation.wrappedValue = pointer
                        case .ended:
                            selection.wrappedValue = nil
                            hoverLocation.wrappedValue = nil
                        }
                    }
            }
        }
    }
}

private struct ChartTooltip: View {
    typealias Row = (label: String, value: String, color: Color)

    let date: Date
    let rows: [Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(date, format: .dateTime.hour().minute().second())
                .font(.caption.weight(.semibold))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 7) {
                    Circle()
                        .fill(row.color)
                        .frame(width: 6, height: 6)
                    Text(row.label)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(row.value)
                        .monospacedDigit()
                }
                .font(.caption)
            }
        }
        .frame(width: 116, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.separator.opacity(0.45), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

private struct FollowingChartTooltip: View {
    let location: CGPoint
    let date: Date
    let rows: [ChartTooltip.Row]

    var body: some View {
        GeometryReader { geometry in
            let tooltipWidth: CGFloat = 136
            let tooltipHeight: CGFloat = rows.count > 1 ? 74 : 54
            let horizontalOffset = tooltipWidth / 2 + 10
            let verticalOffset = tooltipHeight / 2 + 10
            let proposedX = location.x + horizontalOffset + 8 < geometry.size.width
                ? location.x + horizontalOffset
                : location.x - horizontalOffset
            let proposedY = location.y - verticalOffset > 8
                ? location.y - verticalOffset
                : location.y + verticalOffset
            let x = min(max(tooltipWidth / 2 + 4, proposedX), geometry.size.width - tooltipWidth / 2 - 4)
            let y = min(max(tooltipHeight / 2 + 4, proposedY), geometry.size.height - tooltipHeight / 2 - 4)

            ChartTooltip(date: date, rows: rows)
                .position(x: x, y: y)
        }
        .allowsHitTesting(false)
    }
}

private func rateOrUnavailable(_ value: Double?) -> String {
    value.map(ByteRateFormatter.rate) ?? L10n.text("采样缺口")
}

private func percentOrUnavailable(_ value: Double?) -> String {
    value.map(PercentFormatter.cpu) ?? L10n.text("采样缺口")
}

private func nearestPoint<T>(
    _ points: [T],
    to date: Date?,
    timestamp: KeyPath<T, Date>
) -> T? {
    guard let date else { return nil }
    return points.min {
        abs($0[keyPath: timestamp].timeIntervalSince(date))
            < abs($1[keyPath: timestamp].timeIntervalSince(date))
    }
}

func downsampledChartPoints<T>(
    _ points: [T],
    maxCount: Int = 360,
    segment: (T) -> Int,
    values: (T) -> [Double?]
) -> [T] {
    guard points.count > maxCount, maxCount >= 8 else { return points }
    let dimensionCount = max(1, values(points[0]).count)
    let bucketCount = max(1, (maxCount - 2) / (dimensionCount * 2))
    let interiorCount = points.count - 2
    let bucketSize = max(1, Int(ceil(Double(interiorCount) / Double(bucketCount))))
    var selected: Set<Int> = [0, points.count - 1]

    var previousSegment = segment(points[0])
    for index in 1..<points.count {
        let currentSegment = segment(points[index])
        if currentSegment != previousSegment {
            selected.insert(index - 1)
            selected.insert(index)
        }
        previousSegment = currentSegment
    }

    var bucketStart = 1
    let interiorEnd = points.count - 1
    while bucketStart < interiorEnd {
        let bucketEnd = min(interiorEnd, bucketStart + bucketSize)
        var minima = Array(
            repeating: (value: Double.infinity, index: bucketStart),
            count: dimensionCount
        )
        var maxima = Array(
            repeating: (value: -Double.infinity, index: bucketStart),
            count: dimensionCount
        )

        for index in bucketStart..<bucketEnd {
            let pointValues = values(points[index])
            for dimension in 0..<min(dimensionCount, pointValues.count) {
                guard let value = pointValues[dimension] else { continue }
                if value < minima[dimension].value { minima[dimension] = (value, index) }
                if value > maxima[dimension].value { maxima[dimension] = (value, index) }
            }
        }
        for dimension in 0..<dimensionCount where minima[dimension].value.isFinite {
            selected.insert(minima[dimension].index)
            selected.insert(maxima[dimension].index)
        }
        bucketStart = bucketEnd
    }

    return selected.sorted().map { points[$0] }
}

@ViewBuilder
private func emptyState(_ count: Int, title: String) -> some View {
    if count < 2 {
        ContentUnavailableView(title, systemImage: "waveform.path.ecg")
            .controlSize(.small)
    }
}
