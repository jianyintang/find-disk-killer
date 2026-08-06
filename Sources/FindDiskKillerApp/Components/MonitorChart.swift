import Charts
import FindDiskKillerCore
import Observation
import SwiftUI

/// Suppresses chart sweep animations while no window of the app is visible on
/// screen (occluded, minimized or on another Space). Rendering work — and the
/// system-wide compositing cost of the sweep — only matters when the user can
/// actually see it, so background updates switch to instant replacements.
private enum ChartAnimationGate {
    static var hasVisibleWindow: Bool {
        NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
    }
}

@Observable
private final class StreamingChartBuffer<Point> {
    var renderedPoints: [Point]
    var domainStart: TimeInterval
    var domainEnd: TimeInterval
    @ObservationIgnored private let timestamp: KeyPath<Point, Date>
    @ObservationIgnored private var windowDuration: TimeInterval?
    @ObservationIgnored private var transitionTask: Task<Void, Never>?

    init(
        points: [Point],
        timestamp: KeyPath<Point, Date>,
        windowDuration: TimeInterval? = nil
    ) {
        self.renderedPoints = points
        self.timestamp = timestamp
        self.windowDuration = windowDuration
        let domain = Self.domain(
            for: points,
            timestamp: timestamp,
            windowDuration: windowDuration
        )
        self.domainStart = domain.lowerBound
        self.domainEnd = domain.upperBound
    }

    var domain: ClosedRange<Date> {
        ClosedRange(uncheckedBounds: (
            lower: Date(timeIntervalSinceReferenceDate: domainStart),
            upper: Date(timeIntervalSinceReferenceDate: domainEnd)
        ))
    }

    @MainActor
    func update(
        with next: [Point],
        reduceMotion: Bool,
        windowDuration: TimeInterval?
    ) {
        transitionTask?.cancel()
        let currentDates = renderedPoints.map { $0[keyPath: timestamp] }
        let nextDates = next.map { $0[keyPath: timestamp] }
        let durationChanged = self.windowDuration != windowDuration
        self.windowDuration = windowDuration
        guard currentDates != nextDates || durationChanged else { return }
        let nextDomain = Self.domain(
            for: next,
            timestamp: timestamp,
            windowDuration: windowDuration
        )

        let isRolling = currentDates.count == nextDates.count
            && currentDates.count > 1
            && Array(currentDates.dropFirst()) == Array(nextDates.dropLast())
        let isGrowing = nextDates.count == currentDates.count + 1
            && Array(nextDates.dropLast()) == currentDates
        guard !durationChanged,
              !reduceMotion,
              isRolling || isGrowing,
              let latest = next.last
        else {
            replace(with: next, domain: nextDomain)
            return
        }

        withAnimation(.easeInOut(duration: InstrumentDesign.Motion.sampleTransitionDuration)) {
            renderedPoints.append(latest)
            domainStart = nextDomain.lowerBound
            domainEnd = nextDomain.upperBound
        }
        transitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                for: .seconds(InstrumentDesign.Motion.sampleTransitionDuration)
            )
            guard !Task.isCancelled, let self else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.renderedPoints = next
                self.domainStart = nextDomain.lowerBound
                self.domainEnd = nextDomain.upperBound
            }
        }
    }

    func cancelTransition() {
        transitionTask?.cancel()
    }

    @MainActor
    private func replace(with next: [Point], domain: ClosedRange<TimeInterval>) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            renderedPoints = next
            domainStart = domain.lowerBound
            domainEnd = domain.upperBound
        }
    }

    private static func domain(
        for points: [Point],
        timestamp: KeyPath<Point, Date>,
        windowDuration: TimeInterval?
    ) -> ClosedRange<TimeInterval> {
        guard let first = points.first, let last = points.last else { return 0...1 }
        let upper = last[keyPath: timestamp].timeIntervalSinceReferenceDate
        let lower = windowDuration.map { upper - max($0, 1) }
            ?? first[keyPath: timestamp].timeIntervalSinceReferenceDate
        return lower...max(upper, lower + 1)
    }
}

private struct TimelineUpdateKey: Equatable {
    let timestamps: [Date]
    let windowDuration: TimeInterval
}

struct WarningThroughputSample: Equatable {
    let timestamp: Date
    let value: Double?
    let segment: Int
}

struct WarningThroughputPoint: Identifiable, Equatable {
    let id: String
    let timestamp: Date
    let value: Double
}

struct WarningThroughputSegment: Identifiable, Equatable {
    let id: Int
    let points: [WarningThroughputPoint]
}

/// Builds only the continuous portions of a write series that are above the
/// warning threshold. Interpolated threshold crossings keep the red overlay
/// joined to the underlying write line instead of producing isolated points.
func warningThroughputSegments(
    samples: [WarningThroughputSample],
    threshold: Double
) -> [WarningThroughputSegment] {
    guard samples.count > 1 else { return [] }

    var segments: [WarningThroughputSegment] = []
    var current: [WarningThroughputPoint] = []
    var nextID = 0

    func flush() {
        guard current.count > 1 else {
            current.removeAll(keepingCapacity: true)
            return
        }
        segments.append(WarningThroughputSegment(id: nextID, points: current))
        nextID += 1
        current.removeAll(keepingCapacity: true)
    }

    for index in 1..<samples.count {
        let previous = samples[index - 1]
        let next = samples[index]
        guard let previousValue = previous.value,
              let nextValue = next.value,
              previous.segment == next.segment,
              previousValue.isFinite,
              nextValue.isFinite
        else {
            flush()
            continue
        }

        let previousWarning = previousValue > threshold
        let nextWarning = nextValue > threshold
        guard previousWarning || nextWarning else {
            flush()
            continue
        }

        let piece: [WarningThroughputPoint]
        switch (previousWarning, nextWarning) {
        case (true, true):
            piece = [
                WarningThroughputPoint(
                    id: "sample-\(previous.timestamp.timeIntervalSinceReferenceDate)",
                    timestamp: previous.timestamp,
                    value: previousValue
                ),
                WarningThroughputPoint(
                    id: "sample-\(next.timestamp.timeIntervalSinceReferenceDate)",
                    timestamp: next.timestamp,
                    value: nextValue
                )
            ]
        case (false, true), (true, false):
            let delta = nextValue - previousValue
            let fraction = delta == 0
                ? 0
                : (threshold - previousValue) / delta
            let crossingDate = previous.timestamp.addingTimeInterval(
                next.timestamp.timeIntervalSince(previous.timestamp)
                    * min(1, max(0, fraction))
            )
            let crossing = WarningThroughputPoint(
                id: "crossing-\(crossingDate.timeIntervalSinceReferenceDate)",
                timestamp: crossingDate,
                value: threshold
            )
            if previousWarning {
                piece = [
                    WarningThroughputPoint(
                        id: "sample-\(previous.timestamp.timeIntervalSinceReferenceDate)",
                        timestamp: previous.timestamp,
                        value: previousValue
                    ),
                    crossing
                ]
            } else {
                piece = [
                    crossing,
                    WarningThroughputPoint(
                        id: "sample-\(next.timestamp.timeIntervalSinceReferenceDate)",
                        timestamp: next.timestamp,
                        value: nextValue
                    )
                ]
            }
        case (false, false):
            continue
        }

        if let last = current.last, last.timestamp == piece[0].timestamp {
            current.append(contentsOf: piece.dropFirst())
        } else {
            flush()
            current = piece
        }
    }
    flush()
    return segments
}

struct MonitorChart: View {
    let points: [ThroughputPoint]
    var height: CGFloat = 210
    var warningThreshold: Double? = nil
    let windowDuration: TimeInterval
    @State private var timeline: StreamingChartBuffer<ThroughputPoint>
    @State private var hoverDate: Date?
    @State private var hoverLocation: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.visualEffectLevel) private var visualEffectLevel

    init(
        points: [ThroughputPoint],
        height: CGFloat = 210,
        warningThreshold: Double? = nil,
        windowDuration: TimeInterval = SampleRange.minute.seconds
    ) {
        self.points = points
        self.height = height
        self.warningThreshold = warningThreshold
        self.windowDuration = windowDuration
        _timeline = State(initialValue: StreamingChartBuffer(
            points: points,
            timestamp: \.timestamp,
            windowDuration: windowDuration
        ))
    }

    var body: some View {
        let selectedTimestamp = selectedPoint?.timestamp
        let chartPoints = timeline.renderedPoints
        let warningSegments = warningThroughputSegments(
            samples: chartPoints.map {
                WarningThroughputSample(
                    timestamp: $0.timestamp,
                    value: $0.writeBytesPerSecond,
                    segment: $0.segment
                )
            },
            threshold: warningThreshold ?? .greatestFiniteMagnitude
        )
        Chart {
            ForEach(chartPoints) { point in
                if let read = point.readBytesPerSecond {
                if visualEffectLevel.usesChartFills {
                    AreaMark(
                        x: .value(L10n.text("时间"), point.timestamp),
                        yStart: .value(L10n.text("读取"), 0),
                        yEnd: .value(L10n.text("读取"), read),
                        series: .value(L10n.text("系列"), "read-area-\(point.segment)")
                    )
                    .foregroundStyle(InstrumentDesign.ColorRole.diskRead.opacity(0.12))
                    .interpolationMethod(.linear)
                }
                LineMark(
                    x: .value(L10n.text("时间"), point.timestamp),
                    y: .value(L10n.text("读取"), read),
                    series: .value(L10n.text("系列"), "read-\(point.segment)")
                )
                .foregroundStyle(InstrumentDesign.ColorRole.diskRead)
                .lineStyle(StrokeStyle(lineWidth: InstrumentDesign.Stroke.chart))
                .interpolationMethod(.linear)
                }

                if let write = point.writeBytesPerSecond {
                if visualEffectLevel.usesChartFills {
                    AreaMark(
                        x: .value(L10n.text("时间"), point.timestamp),
                        yStart: .value(L10n.text("写入"), 0),
                        yEnd: .value(L10n.text("写入"), write),
                        series: .value(
                            L10n.text("系列"),
                            "write-area-\(point.segment)"
                        )
                    )
                    .foregroundStyle(InstrumentDesign.ColorRole.diskWrite.opacity(0.12))
                    .interpolationMethod(.linear)
                }
                LineMark(
                    x: .value(L10n.text("时间"), point.timestamp),
                    y: .value(L10n.text("写入"), write),
                    series: .value(
                        L10n.text("系列"),
                        "write-\(point.segment)"
                    )
                )
                .foregroundStyle(InstrumentDesign.ColorRole.diskWrite)
                .lineStyle(StrokeStyle(lineWidth: InstrumentDesign.Stroke.chart))
                .interpolationMethod(.linear)
                }

                if selectedTimestamp == point.timestamp {
                    RuleMark(x: .value(L10n.text("选中时间"), point.timestamp))
                        .foregroundStyle(.secondary.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    if let read = point.readBytesPerSecond {
                        PointMark(x: .value(L10n.text("时间"), point.timestamp), y: .value(L10n.text("读取"), read))
                            .foregroundStyle(InstrumentDesign.ColorRole.diskRead)
                    }
                    if let write = point.writeBytesPerSecond {
                        PointMark(x: .value(L10n.text("时间"), point.timestamp), y: .value(L10n.text("写入"), write))
                            .foregroundStyle(
                                isWarning(write)
                                    ? InstrumentDesign.ColorRole.warning
                                    : InstrumentDesign.ColorRole.diskWrite
                            )
                    }
                }
            }

            if let warningThreshold {
                ForEach(warningSegments) { segment in
                    ForEach(segment.points) { point in
                        if visualEffectLevel.usesChartFills {
                            AreaMark(
                                x: .value(L10n.text("时间"), point.timestamp),
                                yStart: .value(L10n.text("警告阈值"), warningThreshold),
                                yEnd: .value(L10n.text("写入"), point.value),
                                series: .value(L10n.text("系列"), "warning-area-\(segment.id)")
                            )
                            .foregroundStyle(InstrumentDesign.ColorRole.warning.opacity(0.10))
                            .interpolationMethod(.linear)
                        }
                        LineMark(
                            x: .value(L10n.text("时间"), point.timestamp),
                            y: .value(L10n.text("写入"), point.value),
                            series: .value(L10n.text("系列"), "warning-\(segment.id)")
                        )
                        .foregroundStyle(InstrumentDesign.ColorRole.warning)
                        .lineStyle(StrokeStyle(lineWidth: InstrumentDesign.Stroke.chart))
                        .interpolationMethod(.linear)
                    }
                }

                RuleMark(y: .value(L10n.text("警告阈值"), warningThreshold))
                    .foregroundStyle(InstrumentDesign.ColorRole.warning.opacity(0.58))
                    .lineStyle(StrokeStyle(lineWidth: 0.75, dash: [5, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text(ByteRateFormatter.rate(warningThreshold))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.10))
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
                    .foregroundStyle(Color.secondary.opacity(0.10))
                AxisValueLabel(format: .dateTime.hour().minute().second())
                    .font(.caption2)
            }
        }
        .chartXScale(domain: timeline.domain)
        .chartPlotStyle { plotArea in
            plotArea.background(Color.primary.opacity(0.012))
        }
        .chartHoverSelection($hoverDate, location: $hoverLocation)
        .frame(height: height)
        .drawingGroup()
        .onChange(of: TimelineUpdateKey(
            timestamps: points.map(\.timestamp),
            windowDuration: windowDuration
        )) { _, _ in
            let suppressSweep = reduceMotion
                || visualEffectLevel.disablesMotion
                || !ChartAnimationGate.hasVisibleWindow
               
            timeline.update(
                with: points,
                reduceMotion: suppressSweep,
                windowDuration: windowDuration
            )
        }
        .onDisappear { timeline.cancelTransition() }
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
                        (L10n.text("读取"), rateOrUnavailable(point.readBytesPerSecond), InstrumentDesign.ColorRole.diskRead),
                        (L10n.text("写入"), rateOrUnavailable(point.writeBytesPerSecond), InstrumentDesign.ColorRole.diskWrite)
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

    private func isWarning(_ value: Double) -> Bool {
        guard let warningThreshold else { return false }
        return value > warningThreshold
    }

    private var selectedPoint: ThroughputPoint? {
        nearestPoint(points, to: hoverDate, timestamp: \.timestamp)
    }
}

struct SystemCPUChart: View {
    let points: [SystemResourcePoint]
    var height: CGFloat = 210
    let windowDuration: TimeInterval
    @State private var timeline: StreamingChartBuffer<SystemResourcePoint>
    @State private var hoverDate: Date?
    @State private var hoverLocation: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.visualEffectLevel) private var visualEffectLevel

    init(
        points: [SystemResourcePoint],
        height: CGFloat = 210,
        windowDuration: TimeInterval = SampleRange.minute.seconds
    ) {
        self.points = points
        self.height = height
        self.windowDuration = windowDuration
        _timeline = State(initialValue: StreamingChartBuffer(
            points: points,
            timestamp: \.timestamp,
            windowDuration: windowDuration
        ))
    }

    var body: some View {
        let selectedTimestamp = selectedPoint?.timestamp
        let chartPoints = timeline.renderedPoints
        Chart(chartPoints) { point in
            if let cpu = point.cpuPercent {
                if visualEffectLevel.usesChartFills {
                    AreaMark(
                        x: .value(L10n.text("时间"), point.timestamp),
                        yStart: .value("CPU", 0),
                        yEnd: .value("CPU", cpu),
                        series: .value(
                            L10n.text("系列"),
                            point.cpuSegment * 2 + (cpu > 80 ? 1 : 0)
                        )
                    )
                    .foregroundStyle(
                        (cpu > 80
                            ? InstrumentDesign.ColorRole.warning
                            : InstrumentDesign.ColorRole.cpu).opacity(0.12)
                    )
                    .interpolationMethod(.linear)
                }
                LineMark(
                    x: .value(L10n.text("时间"), point.timestamp),
                    y: .value("CPU", cpu),
                    series: .value(
                        L10n.text("系列"),
                        point.cpuSegment * 2 + (cpu > 80 ? 1 : 0)
                    )
                )
                .foregroundStyle(
                    cpu > 80
                        ? InstrumentDesign.ColorRole.warning
                        : InstrumentDesign.ColorRole.cpu
                )
                .lineStyle(StrokeStyle(lineWidth: InstrumentDesign.Stroke.chart))
                .interpolationMethod(.linear)
            }
            if point.timestamp == chartPoints.first?.timestamp {
                RuleMark(y: .value(L10n.text("警告阈值"), 80))
                    .foregroundStyle(InstrumentDesign.ColorRole.warning.opacity(0.72))
                    .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [5, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text(L10n.text("警告 80%"))
                            .font(.caption2)
                            .foregroundStyle(InstrumentDesign.ColorRole.warning)
                    }
            }
            if selectedTimestamp == point.timestamp {
                RuleMark(x: .value(L10n.text("选中时间"), point.timestamp))
                    .foregroundStyle(.secondary.opacity(0.55))
                if let cpu = point.cpuPercent {
                    PointMark(x: .value(L10n.text("时间"), point.timestamp), y: .value("CPU", cpu))
                        .foregroundStyle(
                            cpu > 80
                                ? InstrumentDesign.ColorRole.warning
                                : InstrumentDesign.ColorRole.cpu
                        )
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
        .chartXScale(domain: timeline.domain)
        .chartPlotStyle { $0.background(Color.secondary.opacity(0.035)) }
        .chartHoverSelection($hoverDate, location: $hoverLocation)
        .frame(height: height)
        .drawingGroup()
        .onChange(of: TimelineUpdateKey(
            timestamps: points.map(\.timestamp),
            windowDuration: windowDuration
        )) { _, _ in
            let suppressSweep = reduceMotion
                || visualEffectLevel.disablesMotion
                || !ChartAnimationGate.hasVisibleWindow
               
            timeline.update(
                with: points,
                reduceMotion: suppressSweep,
                windowDuration: windowDuration
            )
        }
        .onDisappear { timeline.cancelTransition() }
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
    let windowDuration: TimeInterval
    @State private var timeline: StreamingChartBuffer<SystemResourcePoint>
    @State private var hoverDate: Date?
    @State private var hoverLocation: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.visualEffectLevel) private var visualEffectLevel

    init(
        points: [SystemResourcePoint],
        height: CGFloat = 210,
        windowDuration: TimeInterval = SampleRange.minute.seconds
    ) {
        self.points = points
        self.height = height
        self.windowDuration = windowDuration
        _timeline = State(initialValue: StreamingChartBuffer(
            points: points,
            timestamp: \.timestamp,
            windowDuration: windowDuration
        ))
    }

    var body: some View {
        let selectedTimestamp = selectedPoint?.timestamp
        Chart(timeline.renderedPoints) { point in
            if let receive = point.networkReceiveBytesPerSecond {
                if visualEffectLevel.usesChartFills {
                    AreaMark(
                        x: .value(L10n.text("时间"), point.timestamp),
                        yStart: .value(L10n.text("下载"), 0),
                        yEnd: .value(L10n.text("下载"), receive),
                        series: .value(L10n.text("系列"), "download-area-\(point.networkSegment)")
                    )
                    .foregroundStyle(InstrumentDesign.ColorRole.read.opacity(0.12))
                    .interpolationMethod(.linear)
                }
                LineMark(
                    x: .value(L10n.text("时间"), point.timestamp),
                    y: .value(L10n.text("下载"), receive),
                    series: .value(L10n.text("系列"), "download-\(point.networkSegment)")
                )
                .foregroundStyle(InstrumentDesign.ColorRole.read)
                .lineStyle(StrokeStyle(lineWidth: InstrumentDesign.Stroke.chart))
                .interpolationMethod(.linear)
            }

            if let send = point.networkSendBytesPerSecond {
                if visualEffectLevel.usesChartFills {
                    AreaMark(
                        x: .value(L10n.text("时间"), point.timestamp),
                        yStart: .value(L10n.text("上传"), 0),
                        yEnd: .value(L10n.text("上传"), send),
                        series: .value(L10n.text("系列"), "upload-area-\(point.networkSegment)")
                    )
                    .foregroundStyle(InstrumentDesign.ColorRole.upload.opacity(0.10))
                    .interpolationMethod(.linear)
                }
                LineMark(
                    x: .value(L10n.text("时间"), point.timestamp),
                    y: .value(L10n.text("上传"), send),
                    series: .value(L10n.text("系列"), "upload-\(point.networkSegment)")
                )
                .foregroundStyle(InstrumentDesign.ColorRole.upload)
                .lineStyle(StrokeStyle(lineWidth: InstrumentDesign.Stroke.chart))
                .interpolationMethod(.linear)
            }

            if selectedTimestamp == point.timestamp {
                RuleMark(x: .value(L10n.text("选中时间"), point.timestamp))
                    .foregroundStyle(.secondary.opacity(0.55))
                if let receive = point.networkReceiveBytesPerSecond {
                    PointMark(x: .value(L10n.text("时间"), point.timestamp), y: .value(L10n.text("下载"), receive))
                        .foregroundStyle(InstrumentDesign.ColorRole.read)
                }
                if let send = point.networkSendBytesPerSecond {
                    PointMark(x: .value(L10n.text("时间"), point.timestamp), y: .value(L10n.text("上传"), send))
                        .foregroundStyle(InstrumentDesign.ColorRole.upload)
                }
            }
        }
        .chartLegend(.hidden)
        .resourceRateAxis()
        .resourceTimeAxis()
        .chartXScale(domain: timeline.domain)
        .chartPlotStyle { $0.background(Color.secondary.opacity(0.035)) }
        .chartHoverSelection($hoverDate, location: $hoverLocation)
        .frame(height: height)
        .drawingGroup()
        .onChange(of: TimelineUpdateKey(
            timestamps: points.map(\.timestamp),
            windowDuration: windowDuration
        )) { _, _ in
            let suppressSweep = reduceMotion
                || visualEffectLevel.disablesMotion
                || !ChartAnimationGate.hasVisibleWindow
               
            timeline.update(
                with: points,
                reduceMotion: suppressSweep,
                windowDuration: windowDuration
            )
        }
        .onDisappear { timeline.cancelTransition() }
        .accessibilityLabel(L10n.text("系统网络趋势"))
        .overlay { emptyState(points.count, title: L10n.text("正在收集网络样本")) }
        .overlay {
            if let point = selectedPoint, let hoverLocation {
                FollowingChartTooltip(
                    location: hoverLocation,
                    date: point.timestamp,
                    rows: [
                        (L10n.text("下载"), rateOrUnavailable(point.networkReceiveBytesPerSecond), InstrumentDesign.ColorRole.read),
                        (L10n.text("上传"), rateOrUnavailable(point.networkSendBytesPerSecond), InstrumentDesign.ColorRole.upload)
                    ]
                )
            }
        }
    }

    private var selectedPoint: SystemResourcePoint? {
        nearestPoint(points, to: hoverDate, timestamp: \.timestamp)
    }
}

private struct MemoryChartPoint: Identifiable {
    let timestamp: Date
    let usedBytes: Double
    let segment: Int

    var id: Date { timestamp }
}

struct SystemMemoryChart: View {
    let points: [SystemResourcePoint]
    var height: CGFloat = 210
    let windowDuration: TimeInterval
    @State private var timeline: StreamingChartBuffer<SystemResourcePoint>
    @State private var hoverDate: Date?
    @State private var hoverLocation: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.visualEffectLevel) private var visualEffectLevel

    init(
        points: [SystemResourcePoint],
        height: CGFloat = 210,
        windowDuration: TimeInterval = SampleRange.minute.seconds
    ) {
        self.points = points
        self.height = height
        self.windowDuration = windowDuration
        _timeline = State(initialValue: StreamingChartBuffer(
            points: points,
            timestamp: \.timestamp,
            windowDuration: windowDuration
        ))
    }

    var body: some View {
        let selectedTimestamp = selectedPoint?.timestamp
        let timeLabel = L10n.text("时间")
        let usedLabel = L10n.text("已用内存")
        let chartPoints = memoryChartPoints(from: timeline.renderedPoints)
        let baseline = memoryBaseline(for: chartPoints)
        Chart(chartPoints) { point in
            if visualEffectLevel.usesChartFills {
                AreaMark(
                    x: .value(timeLabel, point.timestamp),
                    yStart: .value(usedLabel, baseline),
                    yEnd: .value(usedLabel, point.usedBytes)
                )
                .foregroundStyle(InstrumentDesign.ColorRole.memory.opacity(0.11))
            }
            LineMark(
                x: .value(timeLabel, point.timestamp),
                y: .value(usedLabel, point.usedBytes)
            )
            .foregroundStyle(InstrumentDesign.ColorRole.memory)
            .lineStyle(StrokeStyle(lineWidth: InstrumentDesign.Stroke.chart))
            if selectedTimestamp == point.timestamp {
                RuleMark(x: .value(L10n.text("选中时间"), point.timestamp))
                    .foregroundStyle(.secondary.opacity(0.55))
            }
        }
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .resourceTimeAxis()
        .chartXScale(domain: timeline.domain)
        .chartPlotStyle { $0.background(Color.secondary.opacity(0.035)) }
        .chartHoverSelection($hoverDate, location: $hoverLocation)
        .frame(height: height)
        .drawingGroup()
        .onChange(of: TimelineUpdateKey(
            timestamps: points.map(\.timestamp),
            windowDuration: windowDuration
        )) { _, _ in
            let suppressSweep = reduceMotion
                || visualEffectLevel.disablesMotion
                || !ChartAnimationGate.hasVisibleWindow
               
            timeline.update(
                with: points,
                reduceMotion: suppressSweep,
                windowDuration: windowDuration
            )
        }
        .onDisappear { timeline.cancelTransition() }
        .accessibilityLabel(L10n.text("系统内存趋势"))
        .accessibilityValue(accessibilitySummary)
        .overlay { emptyState(points.count, title: L10n.text("正在收集内存样本")) }
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

    private var selectedPoint: SystemResourcePoint? {
        nearestPoint(points, to: hoverDate, timestamp: \.timestamp)
    }

    private func memoryChartPoints(from points: [SystemResourcePoint]) -> [MemoryChartPoint] {
        points.compactMap { point in
            guard let used = point.memoryUsedBytes else { return nil }
            return MemoryChartPoint(
                timestamp: point.timestamp,
                usedBytes: Double(used),
                segment: point.memorySegment
            )
        }
    }

    private func memoryBaseline(for points: [MemoryChartPoint]) -> Double {
        guard let minimum = points.map(\.usedBytes).min() else { return 0 }
        return max(0, minimum * 0.985)
    }

    private var accessibilitySummary: String {
        guard let point = points.last, let used = point.memoryUsedBytes else {
            return L10n.text("内存采样缺口")
        }
        return L10n.format("当前已用 %@", ByteRateFormatter.approximateBytes(Double(used)))
    }

    private func tooltipRows(for point: SystemResourcePoint) -> [ChartTooltip.Row] {
        let used = point.memoryUsedBytes.map {
            ByteRateFormatter.approximateBytes(Double($0))
        } ?? L10n.text("采样缺口")
        let compressed = point.memoryCompressedBytes.map {
            ByteRateFormatter.approximateBytes(Double($0))
        } ?? L10n.text("采样缺口")
        return [
            (L10n.text("已用"), used, InstrumentDesign.ColorRole.memory),
            (L10n.text("压缩"), compressed, Color.secondary)
        ]
    }
}

enum ProcessChartKind: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case disk = "磁盘 I/O"
    case network = "网络"
    case memory = "内存"

    var id: String { rawValue }
    var title: String { L10n.text(rawValue) }
}

struct ProcessMetricChart: View {
    let points: [ProcessMetricPoint]
    let kind: ProcessChartKind
    var height: CGFloat = 150
    let windowDuration: TimeInterval
    @State private var timeline: StreamingChartBuffer<ProcessMetricPoint>
    @State private var hoverDate: Date?
    @State private var hoverLocation: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.visualEffectLevel) private var visualEffectLevel

    init(
        points: [ProcessMetricPoint],
        kind: ProcessChartKind,
        height: CGFloat = 150,
        windowDuration: TimeInterval = SampleRange.minute.seconds
    ) {
        self.points = points
        self.kind = kind
        self.height = height
        self.windowDuration = windowDuration
        _timeline = State(initialValue: StreamingChartBuffer(
            points: points,
            timestamp: \.timestamp,
            windowDuration: windowDuration
        ))
    }

    var body: some View {
        let selectedTimestamp = selectedPoint?.timestamp
        let timeLabel = L10n.text("时间")
        let seriesLabel = L10n.text("系列")
        let selectedTimeLabel = L10n.text("选中时间")
        let readLabel = L10n.text("读取")
        let writeLabel = L10n.text("写入")
        let downloadLabel = L10n.text("下载")
        let uploadLabel = L10n.text("上传")
        let chartPoints = timeline.renderedPoints
        let memoryBaseline = processMemoryBaseline(for: chartPoints)
        let cpuWarningSegments = warningThroughputSegments(
            samples: chartPoints.map {
                WarningThroughputSample(
                    timestamp: $0.timestamp,
                    value: $0.cpuPercent,
                    segment: 0
                )
            },
            threshold: 80
        )
        Chart {
            ForEach(chartPoints) { point in
                switch kind {
            case .disk:
                if let read = point.readBytesPerSecond {
                    if visualEffectLevel.usesChartFills {
                        AreaMark(
                            x: .value(timeLabel, point.timestamp),
                            yStart: .value(readLabel, 0),
                            yEnd: .value(readLabel, read),
                            series: .value(seriesLabel, "read-area")
                        )
                        .foregroundStyle(InstrumentDesign.ColorRole.diskRead.opacity(0.12))
                    }
                    LineMark(
                        x: .value(timeLabel, point.timestamp),
                        y: .value(readLabel, read),
                        series: .value(seriesLabel, "read")
                    )
                    .foregroundStyle(InstrumentDesign.ColorRole.diskRead)
                    .lineStyle(StrokeStyle(lineWidth: InstrumentDesign.Stroke.chart))
                    .interpolationMethod(.linear)
                }
                if let write = point.writeBytesPerSecond {
                    if visualEffectLevel.usesChartFills {
                        AreaMark(
                            x: .value(timeLabel, point.timestamp),
                            yStart: .value(writeLabel, 0),
                            yEnd: .value(writeLabel, write),
                            series: .value(seriesLabel, "write-area")
                        )
                        .foregroundStyle(InstrumentDesign.ColorRole.diskWrite.opacity(0.12))
                    }
                    LineMark(
                        x: .value(timeLabel, point.timestamp),
                        y: .value(writeLabel, write),
                        series: .value(seriesLabel, "write")
                    )
                    .foregroundStyle(InstrumentDesign.ColorRole.diskWrite)
                    .lineStyle(StrokeStyle(lineWidth: InstrumentDesign.Stroke.chart))
                    .interpolationMethod(.linear)
                }
            case .cpu:
                if let cpu = point.cpuPercent {
                    if visualEffectLevel.usesChartFills {
                        AreaMark(
                            x: .value(timeLabel, point.timestamp),
                            yStart: .value("CPU", 0),
                            yEnd: .value("CPU", cpu)
                        )
                        .foregroundStyle(InstrumentDesign.ColorRole.cpu.opacity(0.12))
                    }
                    LineMark(
                        x: .value(timeLabel, point.timestamp),
                        y: .value("CPU", cpu)
                    )
                    .foregroundStyle(InstrumentDesign.ColorRole.cpu)
                    .lineStyle(StrokeStyle(lineWidth: InstrumentDesign.Stroke.chart))
                    .interpolationMethod(.linear)
                }
            case .network:
                if let receive = point.networkReceiveBytesPerSecond {
                    if visualEffectLevel.usesChartFills {
                        AreaMark(
                            x: .value(timeLabel, point.timestamp),
                            yStart: .value(downloadLabel, 0),
                            yEnd: .value(downloadLabel, receive),
                            series: .value(seriesLabel, "download-area-\(point.networkSegment)")
                        )
                        .foregroundStyle(InstrumentDesign.ColorRole.read.opacity(0.12))
                    }
                    LineMark(
                        x: .value(timeLabel, point.timestamp),
                        y: .value(downloadLabel, receive),
                        series: .value(seriesLabel, "download-\(point.networkSegment)")
                    )
                    .foregroundStyle(InstrumentDesign.ColorRole.read)
                    .lineStyle(StrokeStyle(lineWidth: InstrumentDesign.Stroke.chart))
                    .interpolationMethod(.linear)
                }
                if let send = point.networkSendBytesPerSecond {
                    if visualEffectLevel.usesChartFills {
                        AreaMark(
                            x: .value(timeLabel, point.timestamp),
                            yStart: .value(uploadLabel, 0),
                            yEnd: .value(uploadLabel, send),
                            series: .value(seriesLabel, "upload-area-\(point.networkSegment)")
                        )
                        .foregroundStyle(InstrumentDesign.ColorRole.upload.opacity(0.10))
                    }
                    LineMark(
                        x: .value(timeLabel, point.timestamp),
                        y: .value(uploadLabel, send),
                        series: .value(seriesLabel, "upload-\(point.networkSegment)")
                    )
                    .foregroundStyle(InstrumentDesign.ColorRole.upload)
                    .lineStyle(StrokeStyle(lineWidth: InstrumentDesign.Stroke.chart))
                    .interpolationMethod(.linear)
                }
            case .memory:
                if visualEffectLevel.usesChartFills {
                    AreaMark(
                        x: .value(timeLabel, point.timestamp),
                        yStart: .value(L10n.text("驻留内存"), memoryBaseline),
                        yEnd: .value(L10n.text("驻留内存"), Double(point.memoryBytes))
                    )
                    .foregroundStyle(InstrumentDesign.ColorRole.memory.opacity(0.11))
                }
                LineMark(
                    x: .value(timeLabel, point.timestamp),
                    y: .value(L10n.text("驻留内存"), Double(point.memoryBytes)),
                    series: .value(seriesLabel, "memory")
                )
                .foregroundStyle(InstrumentDesign.ColorRole.memory)
                .lineStyle(StrokeStyle(lineWidth: InstrumentDesign.Stroke.chart))
                .interpolationMethod(.linear)
            }

                if selectedTimestamp == point.timestamp {
                    RuleMark(x: .value(selectedTimeLabel, point.timestamp))
                        .foregroundStyle(.secondary.opacity(0.55))
                }
            }

            if kind == .cpu {
                ForEach(cpuWarningSegments) { segment in
                    ForEach(segment.points) { point in
                        if visualEffectLevel.usesChartFills {
                            AreaMark(
                                x: .value(timeLabel, point.timestamp),
                                yStart: .value(L10n.text("警告阈值"), 80),
                                yEnd: .value("CPU", point.value),
                                series: .value(seriesLabel, "process-cpu-warning-area-\(segment.id)")
                            )
                            .foregroundStyle(InstrumentDesign.ColorRole.warning.opacity(0.10))
                            .interpolationMethod(.linear)
                        }
                        LineMark(
                            x: .value(timeLabel, point.timestamp),
                            y: .value("CPU", point.value),
                            series: .value(seriesLabel, "process-cpu-warning-\(segment.id)")
                        )
                        .foregroundStyle(InstrumentDesign.ColorRole.warning)
                        .lineStyle(StrokeStyle(lineWidth: InstrumentDesign.Stroke.chart))
                        .interpolationMethod(.linear)
                    }
                }

                RuleMark(y: .value(L10n.text("警告阈值"), 80))
                    .foregroundStyle(InstrumentDesign.ColorRole.warning.opacity(0.58))
                    .lineStyle(StrokeStyle(lineWidth: 0.75, dash: [5, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text(L10n.text("警告 80%"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(kind == .cpu
                            ? PercentFormatter.cpu(number)
                            : kind == .memory
                                ? ByteRateFormatter.approximateBytes(number)
                                : ByteRateFormatter.rate(number))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .resourceTimeAxis()
        .chartXScale(domain: timeline.domain)
        .chartPlotStyle { $0.background(Color.secondary.opacity(0.035)) }
        .chartHoverSelection($hoverDate, location: $hoverLocation)
        .frame(height: height)
        .drawingGroup()
        .onChange(of: TimelineUpdateKey(
            timestamps: points.map(\.timestamp),
            windowDuration: windowDuration
        )) { _, _ in
            let suppressSweep = reduceMotion
                || visualEffectLevel.disablesMotion
                || !ChartAnimationGate.hasVisibleWindow
               
            timeline.update(
                with: points,
                reduceMotion: suppressSweep,
                windowDuration: windowDuration
            )
        }
        .onDisappear { timeline.cancelTransition() }
        .accessibilityLabel(L10n.format("应用%@趋势", kind.title))
        .accessibilityValue(accessibilitySummary)
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

    private var accessibilitySummary: String {
        guard let point = points.last else { return L10n.text("正在收集应用样本") }
        return tooltipRows(for: point)
            .map { "\($0.label) \($0.value)" }
            .joined(separator: L10n.text("，"))
    }

    private func processMemoryBaseline(for points: [ProcessMetricPoint]) -> Double {
        guard let minimum = points.map({ Double($0.memoryBytes) }).min() else { return 0 }
        return max(0, minimum * 0.985)
    }

    private func tooltipRows(for point: ProcessMetricPoint) -> [ChartTooltip.Row] {
        switch kind {
        case .disk:
            [
                (L10n.text("读取"), rateOrUnavailable(point.readBytesPerSecond), InstrumentDesign.ColorRole.diskRead),
                (L10n.text("写入"), rateOrUnavailable(point.writeBytesPerSecond), InstrumentDesign.ColorRole.diskWrite)
            ]
        case .cpu:
            [("CPU", point.cpuPercent.map(PercentFormatter.cpu) ?? L10n.text("不可用"), .blue)]
        case .network:
            [
                (L10n.text("下载"), rateOrUnavailable(point.networkReceiveBytesPerSecond), .green),
                (L10n.text("上传"), rateOrUnavailable(point.networkSendBytesPerSecond), .indigo)
            ]
        case .memory:
            [
                (
                    L10n.text("驻留内存"),
                    ByteRateFormatter.approximateBytes(Double(point.memoryBytes)),
                    InstrumentDesign.ColorRole.memory
                )
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
        .visualEffectMaterialBackground(.thickMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.separator.opacity(0.45), lineWidth: 0.5)
        }
        .visualEffectShadow(color: .black.opacity(0.12), radius: 8, y: 3)
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
