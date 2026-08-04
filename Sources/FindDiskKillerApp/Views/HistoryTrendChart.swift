import AppKit
import Charts
import FindDiskKillerCore
import SwiftUI

enum HistoryTrendMetric: String, CaseIterable, Identifiable {
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

    var chartTitle: String {
        switch self {
        case .disk: L10n.text("磁盘活动趋势")
        case .cpu: L10n.text("CPU 活动趋势")
        case .network: L10n.text("网络活动趋势")
        }
    }

    var styleDomain: [String] {
        switch self {
        case .disk: [L10n.text("写入"), L10n.text("读取")]
        case .cpu: [L10n.text("平均 CPU")]
        case .network: [L10n.text("接收"), L10n.text("发送")]
        }
    }

    var styleRange: [Color] {
        switch self {
        case .disk: [
            InstrumentDesign.ColorRole.diskWrite,
            InstrumentDesign.ColorRole.diskRead
        ]
        case .cpu: [InstrumentDesign.ColorRole.cpu]
        case .network: [InstrumentDesign.ColorRole.read, InstrumentDesign.ColorRole.upload]
        }
    }
}

struct HistoryTrendChart: View {
    let points: [HistoryTrendPoint]
    let metric: HistoryTrendMetric
    let coverage: Double

    private let series: [HistoryChartValue]
    @State private var viewport: HistoryChartViewport
    @State private var selectedDate: Date?
    @State private var plotFrame: CGRect = .zero
    @State private var chartDragOrigin: Date?

    init(
        points: [HistoryTrendPoint],
        metric: HistoryTrendMetric,
        coverage: Double,
        reportDomain: ClosedRange<Date>
    ) {
        self.points = points
        self.metric = metric
        self.coverage = coverage
        series = Self.makeSeries(points: points, metric: metric)

        let dataStart = min(reportDomain.lowerBound, points.first?.timestamp ?? reportDomain.lowerBound)
        let dataEnd = max(reportDomain.upperBound, points.last?.timestamp ?? reportDomain.upperBound)
        let totalDuration = max(60, dataEnd.timeIntervalSince(dataStart))
        let initialDuration = min(totalDuration, max(6 * 3_600, min(totalDuration * 0.28, 30 * 86_400)))
        let minimumDuration = Self.recommendedMinimumDuration(points: points)
        _viewport = State(initialValue: HistoryChartViewport(
            dataDomain: dataStart...dataEnd,
            visibleDuration: initialDuration,
            trailingBlankFraction: 0.15,
            minimumVisibleDuration: minimumDuration
        ))
    }

    var body: some View {
        VStack(spacing: 10) {
            chart
            timelineControls
        }
        .accessibilityElement(children: .contain)
    }

    private var chart: some View {
        Chart {
            ForEach(series) { value in
                LineMark(
                    x: .value(L10n.text("时间"), value.timestamp),
                    y: .value(value.series, value.value),
                    series: .value(L10n.text("连续区间"), value.series + value.segment)
                )
                .foregroundStyle(by: .value(L10n.text("指标"), value.series))
                .interpolationMethod(.monotone)
            }

            if let selectedPoint {
                RuleMark(x: .value(L10n.text("选定时间"), selectedPoint.timestamp))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
        }
        .chartForegroundStyleScale(domain: metric.styleDomain, range: metric.styleRange)
        .chartLegend(position: .top, alignment: .leading, spacing: 14)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let measurement = value.as(Double.self) {
                        Text(metric == .cpu
                            ? PercentFormatter.cpu(measurement)
                            : ByteRateFormatter.rate(measurement))
                    }
                }
            }
        }
        .chartPlotStyle { plotArea in
            plotArea.background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: HistoryChartPlotFrameKey.self,
                        value: geometry.frame(in: .named("history-chart"))
                    )
                }
            }
            .clipped()
        }
        .coordinateSpace(name: "history-chart")
        .chartXScale(domain: viewport.visibleDomain)
        .chartGesture { proxy in
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if chartDragOrigin == nil {
                        chartDragOrigin = viewport.scrollPosition
                    }
                    let moved = abs(value.translation.width) > 2 || abs(value.translation.height) > 2
                    guard moved, let chartDragOrigin else { return }
                    viewport.pan(
                        from: chartDragOrigin,
                        horizontalTranslation: Double(value.translation.width),
                        plotWidth: Double(max(1, plotFrame.width))
                    )
                    selectedDate = nil
                }
                .onEnded { value in
                    defer { chartDragOrigin = nil }
                    let isClick = abs(value.translation.width) < 4 && abs(value.translation.height) < 4
                    guard isClick,
                          let date: Date = proxy.value(atX: value.location.x) else { return }
                    selectedDate = viewport.nearestDate(
                        to: date,
                        candidates: points.map(\.timestamp)
                    )
                }
        }
        .onPreferenceChange(HistoryChartPlotFrameKey.self) { frame in
            guard frame.width > 0 else { return }
            plotFrame = frame
        }
        .frame(height: 270)
        .background {
            ChartScrollWheelMonitor { deltaY, horizontalFraction in
                let anchor = viewport.scrollPosition.addingTimeInterval(
                    viewport.visibleDuration * horizontalFraction
                )
                let factor = min(1.35, max(0.74, exp(-deltaY * 0.025)))
                viewport.zoom(by: factor, anchor: anchor)
                selectedDate = nil
            }
        }
        .overlay(alignment: .topTrailing) {
            if let selectedPoint {
                tooltip(selectedPoint)
                    .padding(.top, 30)
                    .padding(.trailing, 8)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: selectedDate)
        .accessibilityLabel(metric.chartTitle)
        .accessibilityValue(accessibilitySummary)
    }

    private var timelineControls: some View {
        GeometryReader { geometry in
            HStack(spacing: 12) {
                HistoryTimelineNavigator(
                    progress: scrollProgressBinding,
                    visibleFraction: navigatorVisibleFraction,
                    isEnabled: viewport.canScroll
                )

                HStack(spacing: 0) {
                    Button {
                        zoom(by: 1.5)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .frame(width: 28, height: 24)
                    .disabled(viewport.visibleDuration >= viewport.maximumVisibleDuration - 0.5)
                    .help(L10n.text("缩小时间轴"))
                    .accessibilityLabel(L10n.text("缩小时间轴"))

                    Divider().frame(height: 14)

                    Text(visibleDurationText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 62, height: 26, alignment: .center)

                    Divider().frame(height: 14)

                    Button {
                        zoom(by: 2 / 3)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .frame(width: 28, height: 24)
                    .disabled(viewport.visibleDuration <= viewport.minimumVisibleDuration + 0.5)
                    .help(L10n.text("放大时间轴"))
                    .accessibilityLabel(L10n.text("放大时间轴"))
                }
                .buttonStyle(.borderless)
                .background(
                    Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
            }
            .padding(.leading, plotFrame.width > 0 ? plotFrame.minX : 72)
            .padding(.trailing, plotFrame.width > 0
                ? max(0, geometry.size.width - plotFrame.maxX)
                : 8)
        }
        .frame(height: 30)
        .padding(.top, 7)
    }

    private var scrollProgressBinding: Binding<Double> {
        Binding(
            get: { viewport.scrollProgress },
            set: {
                viewport.setProgress($0)
                selectedDate = nil
            }
        )
    }

    private var selectedPoint: HistoryTrendPoint? {
        guard let selectedDate else { return nil }
        return points.min {
            abs($0.timestamp.timeIntervalSince(selectedDate))
                < abs($1.timestamp.timeIntervalSince(selectedDate))
        }
    }

    private var navigatorVisibleFraction: Double {
        viewport.navigatorVisibleFraction
    }

    private var visibleDurationText: String {
        let duration = viewport.visibleDuration
        if duration < 3_600 {
            return L10n.format("%.0f 分钟", duration / 60)
        }
        if duration < 86_400 {
            return L10n.format("%.0f 小时", duration / 3_600)
        }
        return L10n.format("%.0f 天", duration / 86_400)
    }

    private func zoom(by factor: Double) {
        let anchor = viewport.scrollPosition.addingTimeInterval(viewport.visibleDuration / 2)
        viewport.zoom(by: factor, anchor: anchor)
        selectedDate = nil
    }

    private func tooltip(_ point: HistoryTrendPoint) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.date(point.timestamp, date: .abbreviated, time: .shortened))
                .font(.caption.weight(.semibold))

            switch metric {
            case .disk:
                tooltipValue(
                    L10n.text("写入"),
                    point.diskObservedSeconds > 0
                        ? ByteRateFormatter.rate(Self.rate(
                            point.diskWriteBytes,
                            duration: point.diskObservedSeconds
                        ))
                        : L10n.text("不可用"),
                    color: InstrumentDesign.ColorRole.diskWrite
                )
                tooltipValue(
                    L10n.text("读取"),
                    point.diskObservedSeconds > 0
                        ? ByteRateFormatter.rate(Self.rate(
                            point.diskReadBytes,
                            duration: point.diskObservedSeconds
                        ))
                        : L10n.text("不可用"),
                    color: InstrumentDesign.ColorRole.diskRead
                )
            case .cpu:
                tooltipValue(
                    L10n.text("平均 CPU"),
                    point.averageCPUPercent.map(PercentFormatter.cpu) ?? L10n.text("不可用"),
                    color: InstrumentDesign.ColorRole.cpu
                )
                tooltipValue(
                    L10n.text("峰值 CPU"),
                    point.peakCPUPercent.map(PercentFormatter.cpu) ?? L10n.text("不可用"),
                    color: InstrumentDesign.ColorRole.cpu.opacity(0.7)
                )
            case .network:
                tooltipValue(
                    L10n.text("接收"),
                    point.networkObservedSeconds > 0
                        ? ByteRateFormatter.rate(Self.rate(
                            point.networkReceiveBytes,
                            duration: point.networkObservedSeconds
                        ))
                        : L10n.text("不可用"),
                    color: InstrumentDesign.ColorRole.read
                )
                tooltipValue(
                    L10n.text("发送"),
                    point.networkObservedSeconds > 0
                        ? ByteRateFormatter.rate(Self.rate(
                            point.networkSendBytes,
                            duration: point.networkObservedSeconds
                        ))
                        : L10n.text("不可用"),
                    color: InstrumentDesign.ColorRole.upload
                )
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityHidden(true)
    }

    private func tooltipValue(_ title: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).fontWeight(.medium).monospacedDigit()
        }
        .font(.caption)
        .frame(minWidth: 150)
    }

    private var accessibilitySummary: String {
        if let selectedPoint {
            return [
                L10n.date(selectedPoint.timestamp, date: .abbreviated, time: .shortened),
                pointSummary(selectedPoint)
            ].joined(separator: ", ")
        }
        return L10n.format(
            "数据覆盖 %.0f%%，共 %d 个数据点",
            coverage * 100,
            points.count
        )
    }

    private func pointSummary(_ point: HistoryTrendPoint) -> String {
        switch metric {
        case .disk:
            guard point.diskObservedSeconds > 0 else { return L10n.text("不可用") }
            return [
                "\(L10n.text("写入")) \(ByteRateFormatter.rate(Self.rate(point.diskWriteBytes, duration: point.diskObservedSeconds)))",
                "\(L10n.text("读取")) \(ByteRateFormatter.rate(Self.rate(point.diskReadBytes, duration: point.diskObservedSeconds)))"
            ].joined(separator: ", ")
        case .cpu:
            return [
                "\(L10n.text("平均 CPU")) \(point.averageCPUPercent.map(PercentFormatter.cpu) ?? L10n.text("不可用"))",
                "\(L10n.text("峰值 CPU")) \(point.peakCPUPercent.map(PercentFormatter.cpu) ?? L10n.text("不可用"))"
            ].joined(separator: ", ")
        case .network:
            guard point.networkObservedSeconds > 0 else { return L10n.text("不可用") }
            return [
                "\(L10n.text("接收")) \(ByteRateFormatter.rate(Self.rate(point.networkReceiveBytes, duration: point.networkObservedSeconds)))",
                "\(L10n.text("发送")) \(ByteRateFormatter.rate(Self.rate(point.networkSendBytes, duration: point.networkObservedSeconds)))"
            ].joined(separator: ", ")
        }
    }

    private static func rate(_ bytes: UInt64, duration: TimeInterval) -> Double {
        Double(bytes) / max(1, duration)
    }

    private static func makeSeries(
        points: [HistoryTrendPoint],
        metric: HistoryTrendMetric
    ) -> [HistoryChartValue] {
        var values: [HistoryChartValue] = []
        var segment = 0
        var previous: HistoryTrendPoint?
        var metricSeriesInterrupted = false

        for point in points {
            if point.startsNewSegment {
                segment += 1
                metricSeriesInterrupted = false
            } else if let previous {
                let expectedStep = max(previous.duration, point.duration)
                if point.timestamp.timeIntervalSince(previous.timestamp) > expectedStep * 1.8 {
                    segment += 1
                }
            }

            switch metric {
            case .disk:
                if point.diskObservedSeconds > 0 {
                    if metricSeriesInterrupted {
                        segment += 1
                        metricSeriesInterrupted = false
                    }
                    let availableSegmentID = "-\(segment)"
                    values.append(.init(
                        timestamp: point.timestamp,
                        series: L10n.text("写入"),
                        segment: availableSegmentID,
                        value: rate(point.diskWriteBytes, duration: point.diskObservedSeconds)
                    ))
                    values.append(.init(
                        timestamp: point.timestamp,
                        series: L10n.text("读取"),
                        segment: availableSegmentID,
                        value: rate(point.diskReadBytes, duration: point.diskObservedSeconds)
                    ))
                } else if !values.isEmpty {
                    metricSeriesInterrupted = true
                }
            case .cpu:
                if let cpu = point.averageCPUPercent {
                    if metricSeriesInterrupted {
                        segment += 1
                        metricSeriesInterrupted = false
                    }
                    values.append(.init(
                        timestamp: point.timestamp,
                        series: L10n.text("平均 CPU"),
                        segment: "-\(segment)",
                        value: cpu
                    ))
                } else if !values.isEmpty {
                    metricSeriesInterrupted = true
                }
            case .network:
                if point.networkObservedSeconds > 0 {
                    if metricSeriesInterrupted {
                        segment += 1
                        metricSeriesInterrupted = false
                    }
                    let availableSegmentID = "-\(segment)"
                    values.append(.init(
                        timestamp: point.timestamp,
                        series: L10n.text("接收"),
                        segment: availableSegmentID,
                        value: rate(point.networkReceiveBytes, duration: point.networkObservedSeconds)
                    ))
                    values.append(.init(
                        timestamp: point.timestamp,
                        series: L10n.text("发送"),
                        segment: availableSegmentID,
                        value: rate(point.networkSendBytes, duration: point.networkObservedSeconds)
                    ))
                } else if !values.isEmpty {
                    metricSeriesInterrupted = true
                }
            }
            previous = point
        }
        return values
    }

    static func recommendedMinimumDuration(points: [HistoryTrendPoint]) -> TimeInterval {
        let durations = points.map(\.duration).filter { $0 > 0 }.sorted()
        let deltas = zip(points, points.dropFirst())
            .compactMap { previous, current -> TimeInterval? in
                let delta = current.timestamp.timeIntervalSince(previous.timestamp)
                let expectedStep = max(previous.duration, current.duration)
                guard !current.startsNewSegment,
                      delta > 0,
                      delta <= expectedStep * 1.8 else { return nil }
                return delta
            }
            .sorted()
        let typicalDuration = durations.isEmpty ? 60 : durations[durations.count / 2]
        let typicalDelta = deltas.isEmpty ? typicalDuration : deltas[deltas.count / 2]
        return max(60, max(typicalDuration, typicalDelta) * 2)
    }
}

private struct HistoryTimelineNavigator: View {
    @Binding var progress: Double
    let visibleFraction: Double
    let isEnabled: Bool
    @State private var isHovered = false
    @State private var isDragging = false
    @State private var dragGrabOffset: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let thumbWidth = min(width, max(40, width * min(1, max(0, visibleFraction))))
            let travel = max(0, width - thumbWidth)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
                    .overlay {
                        TimelineTickMarks()
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.075), lineWidth: 1)
                    }
                    .frame(height: 20)

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor.opacity(isHovered || isDragging ? 0.2 : 0.13))
                    .frame(width: thumbWidth, height: 16)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(
                                Color.accentColor.opacity(isHovered || isDragging ? 0.7 : 0.42),
                                lineWidth: 1
                            )
                    }
                    .overlay {
                        HStack(spacing: 2) {
                            Capsule().fill(Color.accentColor.opacity(0.55)).frame(width: 1, height: 6)
                            Capsule().fill(Color.accentColor.opacity(0.55)).frame(width: 1, height: 6)
                        }
                    }
                    .offset(x: travel * min(1, max(0, progress)))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled, travel > 0 else { return }
                        isDragging = true
                        if dragGrabOffset == nil {
                            let thumbOrigin = travel * min(1, max(0, progress))
                            let startedOnThumb = value.startLocation.x >= thumbOrigin
                                && value.startLocation.x <= thumbOrigin + thumbWidth
                            dragGrabOffset = startedOnThumb
                                ? value.startLocation.x - thumbOrigin
                                : thumbWidth / 2
                        }
                        progress = min(1, max(0, (value.location.x - (dragGrabOffset ?? 0)) / travel))
                    }
                    .onEnded { _ in
                        isDragging = false
                        dragGrabOffset = nil
                    }
            )
            .onHover { isHovered = $0 }
        }
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement()
        .accessibilityLabel(L10n.text("浏览时间轴"))
        .accessibilityValue(L10n.percent(progress))
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: progress = min(1, progress + 0.1)
            case .decrement: progress = max(0, progress - 0.1)
            @unknown default: break
            }
        }
    }
}

private struct TimelineTickMarks: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 1..<8 {
            let x = rect.minX + rect.width * CGFloat(index) / 8
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        return path
    }
}

private struct HistoryChartPlotFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct HistoryChartValue: Identifiable {
    let timestamp: Date
    let series: String
    let segment: String
    let value: Double

    var id: String { "\(timestamp.timeIntervalSince1970)-\(series)-\(segment)" }
}

private struct ChartScrollWheelMonitor: NSViewRepresentable {
    let onZoom: (CGFloat, Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onZoom: onZoom)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.view = view
        context.coordinator.onZoom = onZoom
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var onZoom: (CGFloat, Double) -> Void
        private var monitor: Any?

        init(onZoom: @escaping (CGFloat, Double) -> Void) {
            self.onZoom = onZoom
        }

        func installMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handle(event) ? nil : event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let view,
                  view.window === event.window,
                  abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                  abs(event.scrollingDeltaY) > 0.01 else { return false }
            let location = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(location), view.bounds.width > 0 else { return false }
            let fraction = min(1, max(0, location.x / view.bounds.width))
            if event.momentumPhase.isEmpty {
                onZoom(event.scrollingDeltaY, fraction)
            }
            return true
        }
    }
}
