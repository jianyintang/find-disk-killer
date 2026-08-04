import AppKit
import Charts
import FindDiskKillerCore
import SwiftUI

private struct WindowLiveResizeEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isWindowLiveResizing: Bool {
        get { self[WindowLiveResizeEnvironmentKey.self] }
        set { self[WindowLiveResizeEnvironmentKey.self] = newValue }
    }
}

enum InstrumentDesign {
    enum Radius {
        static let panel: CGFloat = 8
        static let control: CGFloat = 6
        static let icon: CGFloat = 7
    }

    enum Spacing {
        static let compact: CGFloat = 6
        static let related: CGFloat = 10
        static let section: CGFloat = 18
        static let page: CGFloat = 20
    }

    enum Stroke {
        static let hairline: CGFloat = 0.6
        static let chart: CGFloat = 1.7
    }

    enum Layout {
        static let diagnosticIdentityWidth: CGFloat = 290
    }

    enum Motion {
        // A 360 ms sweep remains legible as a physical timeline advance while
        // keeping several live instruments from holding the window at display
        // refresh rate for a substantial part of every sampling interval.
        static let sampleTransitionDuration = 0.36
    }

    enum Energy {
        static let cpuSegments = 10
        static let segmentGap: CGFloat = 1.25
        static let coreGap: CGFloat = 2.5
    }

    enum ColorRole {
        static let cpu = Color(red: 0.30, green: 0.46, blue: 0.62)
        static let read = Color(red: 0.28, green: 0.60, blue: 0.65)
        static let write = Color(red: 0.75, green: 0.47, blue: 0.18)
        static let diskRead = Color(red: 0.52, green: 0.57, blue: 0.62)
        static let diskWrite = Color(red: 0.31, green: 0.62, blue: 0.47)
        static let healthy = Color(red: 0.31, green: 0.61, blue: 0.35)
        static let memory = Color(red: 0.53, green: 0.38, blue: 0.64)
        static let upload = Color(red: 0.45, green: 0.38, blue: 0.65)
        static let warning = Color(red: 0.75, green: 0.24, blue: 0.22)
        static let cleanup = Color(red: 0.28, green: 0.59, blue: 0.53)
    }

    enum Palette {
        static let canvas = adaptiveColor(
            light: NSColor(srgbRed: 0.925, green: 0.94, blue: 0.95, alpha: 1),
            dark: NSColor(srgbRed: 0.035, green: 0.045, blue: 0.052, alpha: 1)
        )
        static let canvasRaised = adaptiveColor(
            light: NSColor(srgbRed: 0.965, green: 0.973, blue: 0.978, alpha: 1),
            dark: NSColor(srgbRed: 0.060, green: 0.073, blue: 0.081, alpha: 1)
        )
        static let sidebarTint = adaptiveColor(
            light: NSColor(srgbRed: 0.86, green: 0.885, blue: 0.90, alpha: 0.58),
            dark: NSColor(srgbRed: 0.075, green: 0.092, blue: 0.102, alpha: 0.70)
        )

        private static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            })
        }
    }
}

struct InstrumentCanvas: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isWindowLiveResizing) private var isWindowLiveResizing

    var body: some View {
        ZStack {
            InstrumentDesign.Palette.canvas
            if !reduceTransparency && !isWindowLiveResizing {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(colorScheme == .dark ? 0.46 : 0.34)
            }
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color.white.opacity(0.028), .clear, Color.black.opacity(0.16)]
                    : [Color.white.opacity(0.34), .clear, Color.black.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct GlassSurface<Content: View>: View {
    let content: Content
    var cornerRadius: CGFloat = InstrumentDesign.Radius.panel
    var padding: CGFloat = InstrumentDesign.Spacing.section

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isWindowLiveResizing) private var isWindowLiveResizing

    init(
        cornerRadius: CGFloat = InstrumentDesign.Radius.panel,
        padding: CGFloat = InstrumentDesign.Spacing.section,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background { surfaceBackground }
            .overlay { edgeTreatment }
            .shadow(
                color: .black.opacity(isWindowLiveResizing ? 0 : (colorScheme == .dark ? 0.38 : 0.10)),
                radius: isWindowLiveResizing ? 0 : (colorScheme == .dark ? 9 : 7),
                y: isWindowLiveResizing ? 0 : 3
            )
            .shadow(
                color: .white.opacity(isWindowLiveResizing ? 0 : (colorScheme == .dark ? 0.025 : 0.30)),
                radius: isWindowLiveResizing ? 0 : 1,
                y: isWindowLiveResizing ? 0 : -0.5
            )
    }

    @ViewBuilder
    private var surfaceBackground: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency || isWindowLiveResizing {
            shape.fill(InstrumentDesign.Palette.canvasRaised)
        } else {
            shape
                .fill(.ultraThinMaterial)
                .overlay {
                    shape.fill(colorScheme == .dark
                        ? Color.black.opacity(0.16)
                        : Color.white.opacity(0.22)
                    )
                }
                .overlay {
                    shape.fill(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [Color.white.opacity(0.045), .clear, Color.black.opacity(0.10)]
                                : [Color.white.opacity(0.30), .clear, Color.black.opacity(0.025)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
        }
    }

    private var edgeTreatment: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return ZStack {
            shape.strokeBorder(
                Color.primary.opacity(contrast == .increased ? 0.40 : 0.13),
                lineWidth: contrast == .increased ? 1 : 0.75
            )
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.20 : 0.72),
                        Color.white.opacity(0.025),
                        Color.black.opacity(colorScheme == .dark ? 0.34 : 0.10)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: InstrumentDesign.Stroke.hairline
            )
            shape
                .inset(by: 1.25)
                .strokeBorder(
                    Color.white.opacity(colorScheme == .dark ? 0.035 : 0.20),
                    lineWidth: 0.5
                )
        }
        .accessibilityHidden(true)
    }
}

extension View {
    func glassSurface(
        cornerRadius: CGFloat = InstrumentDesign.Radius.panel,
        padding: CGFloat = InstrumentDesign.Spacing.section
    ) -> some View {
        GlassSurface(cornerRadius: cornerRadius, padding: padding) { self }
    }
}

struct WindowLiveResizeObserver: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onChange = onChange
        DispatchQueue.main.async {
            context.coordinator.observe(nsView.window)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator {
        var onChange: @MainActor (Bool) -> Void
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(onChange: @escaping @MainActor (Bool) -> Void) {
            self.onChange = onChange
        }

        func observe(_ nextWindow: NSWindow?) {
            guard window !== nextWindow else { return }
            stopObserving()
            guard let nextWindow else { return }
            window = nextWindow
            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: NSWindow.willStartLiveResizeNotification,
                    object: nextWindow,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onChange(true) }
                },
                center.addObserver(
                    forName: NSWindow.didEndLiveResizeNotification,
                    object: nextWindow,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onChange(false) }
                }
            ]
            if nextWindow.inLiveResize { onChange(true) }
        }

        func stopObserving() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
            window = nil
        }
    }
}

struct DataValue: View {
    let value: String
    let unit: String?
    var size: CGFloat = 36
    var color: Color = .primary

    var body: some View {
        ViewThatFits(in: .horizontal) {
            valueLine(size: size)
            valueLine(size: max(23, size * 0.74))
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    private func valueLine(size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value)
                .font(.system(size: size, weight: .light, design: .default))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            if let unit, !unit.isEmpty {
                Text(unit)
                    .font(.system(size: max(11, size * 0.32), weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .lineLimit(1)
    }
}

struct GlassMetricTile<Value: View, Visualization: View>: View {
    let title: String
    let symbol: String
    let accent: Color
    let accessibilitySummary: String
    @ViewBuilder let value: () -> Value
    @ViewBuilder let visualization: () -> Visualization

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text(title))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Spacer(minLength: 8)
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(accent.opacity(0.82))
                    .frame(width: 28, height: 24)
                    .background(accent.opacity(0.075), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
            }
            value()
            visualization()
                .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 64)
        }
        .frame(maxWidth: .infinity, minHeight: 158, alignment: .topLeading)
        .glassSurface(padding: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text(accessibilitySummary))
    }
}

struct MicroHistogram: View {
    let values: [Double?]
    let accent: Color
    var warningThreshold: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let finite = values.compactMap { $0 }.filter(\.isFinite)
            let ceiling = max(finite.max() ?? 1, warningThreshold ?? 0, 1)
            let count = max(values.count, 1)
            let gap: CGFloat = 3
            let width = max(2, (geometry.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    let normalized = min(1, max(0, (value ?? 0) / ceiling))
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(barColor(value))
                        .frame(width: width, height: max(3, geometry.size.height * normalized))
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 0.5),
                            value: normalized
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .accessibilityHidden(true)
    }

    private func barColor(_ value: Double?) -> Color {
        guard let value else { return Color.secondary.opacity(0.14) }
        if let warningThreshold, value > warningThreshold {
            return InstrumentDesign.ColorRole.warning
        }
        return accent.opacity(0.70)
    }
}

struct CPUCoreEnergyBars: View {
    let cores: [CPUCoreUsage]

    var body: some View {
        GeometryReader { geometry in
            let count = max(cores.count, 1)
            let gap = min(
                CGFloat(4),
                max(InstrumentDesign.Energy.coreGap, geometry.size.width / 90)
            )
            let barWidth = max(
                3,
                (geometry.size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            )
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(cores) { core in
                    CPUCoreEnergyBar(percent: core.percent)
                        .frame(width: barWidth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .accessibilityHidden(true)
    }
}

private struct CPUCoreEnergyBar: View {
    let percent: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let fraction = min(1, max(0, percent / 100))
            let segments = InstrumentDesign.Energy.cpuSegments
            let gap = InstrumentDesign.Energy.segmentGap
            let segmentHeight = max(
                1.5,
                (geometry.size.height - gap * CGFloat(segments - 1)) / CGFloat(segments)
            )
            VStack(spacing: gap) {
                ForEach((0..<segments).reversed(), id: \.self) { index in
                    let activation = min(
                        1,
                        max(0, fraction * Double(segments) - Double(index))
                    )
                    CPUCoreEnergySegment(
                        activation: activation,
                        color: fillColor,
                        cornerRadius: min(
                            1.35,
                            segmentHeight * 0.28,
                            geometry.size.width * 0.18
                        )
                    )
                    .frame(height: segmentHeight)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.48),
                        value: activation
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private var fillColor: Color {
        percent > 80 ? InstrumentDesign.ColorRole.warning : InstrumentDesign.ColorRole.cpu
    }
}

private struct CPUCoreEnergySegment: View {
    let activation: Double
    let color: Color
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack(alignment: .bottom) {
            shape.fill(Color.secondary.opacity(0.12))
            shape
                .fill(color.opacity(0.78))
                .scaleEffect(y: activation, anchor: .bottom)
        }
        .overlay {
            shape.strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
        }
        .clipped()
    }
}

private struct InstrumentSparklineSample: Identifiable {
    let id: Int
    let value: Double?
}

private struct StreamingSparklineShape: Shape {
    let values: [Double?]
    let capacity: Int
    let baseCount: Int
    let closesToBaseline: Bool
    var phase: Double
    var lowerBound: Double
    var upperBound: Double

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(phase, AnimatablePair(lowerBound, upperBound)) }
        set {
            phase = newValue.first
            lowerBound = newValue.second.first
            upperBound = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var result = Path()
        let resolvedCapacity = max(capacity, baseCount, 2)
        let denominator = CGFloat(resolvedCapacity - 1)
        let firstSlot = resolvedCapacity - baseCount
        let valueSpan = max(upperBound - lowerBound, 1)
        var segment: [CGPoint] = []

        func point(index: Int, value: Double) -> CGPoint {
            let slot = CGFloat(firstSlot + index) - CGFloat(phase)
            let x = slot / denominator * rect.width
            let normalized = (value - lowerBound) / valueSpan
            return CGPoint(x: x, y: rect.maxY - CGFloat(normalized) * rect.height)
        }

        func appendSegment(_ points: [CGPoint], to path: inout Path) {
            guard let first = points.first, let last = points.last else { return }
            path.move(to: first)
            if points.count == 1, !closesToBaseline {
                path.move(to: CGPoint(x: first.x - 1.5, y: first.y))
                path.addLine(to: CGPoint(x: first.x + 1.5, y: first.y))
                return
            }
            for point in points.dropFirst() { path.addLine(to: point) }
            if closesToBaseline {
                path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
                path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
                path.closeSubpath()
            }
        }

        for (index, value) in values.enumerated() {
            guard let value, value.isFinite else {
                appendSegment(segment, to: &result)
                segment.removeAll(keepingCapacity: true)
                continue
            }
            segment.append(point(index: index, value: value))
        }
        appendSegment(segment, to: &result)
        return result
    }
}

struct InstrumentSparkline: View {
    let values: [Double?]
    let color: Color
    let capacity: Int
    @State private var samples: [InstrumentSparklineSample]
    @State private var nextSampleID: Int
    @State private var layoutBaseCount: Int
    @State private var scrollProgress = 0.0
    @State private var transitionTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(values: [Double?], color: Color, capacity: Int? = nil) {
        self.values = values
        self.color = color
        self.capacity = max(capacity ?? values.count, 2)
        let initial = values.enumerated().map {
            InstrumentSparklineSample(id: $0.offset, value: $0.element)
        }
        _samples = State(initialValue: initial)
        _nextSampleID = State(initialValue: initial.count)
        _layoutBaseCount = State(initialValue: initial.count)
    }

    var body: some View {
        ZStack {
            sparklineShape(closesToBaseline: true)
                .fill(color.opacity(0.13))
            sparklineShape(closesToBaseline: false)
                .stroke(
                    color,
                    style: StrokeStyle(
                        lineWidth: InstrumentDesign.Stroke.chart,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
        }
        .clipped()
        .onChange(of: values) { _, nextValues in
            updateSamples(nextValues)
        }
        .onDisappear { transitionTask?.cancel() }
        .accessibilityHidden(true)
    }

    private func sparklineShape(closesToBaseline: Bool) -> StreamingSparklineShape {
        StreamingSparklineShape(
            values: samples.map(\.value),
            capacity: capacity,
            baseCount: layoutBaseCount,
            closesToBaseline: closesToBaseline,
            phase: scrollProgress,
            lowerBound: lowerBound,
            upperBound: upperBound
        )
    }

    private var lowerBound: Double {
        let finite = samples.compactMap(\.value).filter(\.isFinite)
        return min(0, finite.min() ?? 0)
    }

    private var upperBound: Double {
        let finite = samples.compactMap(\.value).filter(\.isFinite)
        let low = lowerBound
        let high = finite.max() ?? 1
        return max(high, low + max(abs(high) * 0.08, 1))
    }

    private func updateSamples(_ nextValues: [Double?]) {
        transitionTask?.cancel()
        let currentValues = samples.map(\.value)
        guard currentValues != nextValues else { return }

        let isRolling = currentValues.count == nextValues.count
            && currentValues.count > 1
            && Array(currentValues.dropFirst()) == Array(nextValues.dropLast())
        let isGrowing = nextValues.count == currentValues.count + 1
            && Array(nextValues.dropLast()) == currentValues
        guard !reduceMotion, isRolling || isGrowing
        else {
            replaceSamples(with: nextValues)
            return
        }

        let latest = nextValues[nextValues.count - 1]
        layoutBaseCount = currentValues.count
        withAnimation(.easeInOut(duration: InstrumentDesign.Motion.sampleTransitionDuration)) {
            samples.append(InstrumentSparklineSample(id: nextSampleID, value: latest))
            scrollProgress = 1
        }
        nextSampleID += 1
        transitionTask = Task { @MainActor in
            try? await Task.sleep(
                for: .seconds(InstrumentDesign.Motion.sampleTransitionDuration)
            )
            guard !Task.isCancelled else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if isRolling { samples.removeFirst() }
                layoutBaseCount = nextValues.count
                scrollProgress = 0
            }
        }
    }

    private func replaceSamples(with nextValues: [Double?]) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            let currentValues = samples.map(\.value)
            if nextValues.count == currentValues.count + 1,
               Array(nextValues.dropLast()) == currentValues {
                samples.append(InstrumentSparklineSample(
                    id: nextSampleID,
                    value: nextValues[nextValues.count - 1]
                ))
                nextSampleID += 1
            } else {
                var sampleID = nextSampleID
                samples = nextValues.map { value in
                    defer { sampleID += 1 }
                    return InstrumentSparklineSample(id: sampleID, value: value)
                }
                nextSampleID = sampleID
            }
            layoutBaseCount = nextValues.count
            scrollProgress = 0
        }
    }
}

private struct DiskTimelineSample: Identifiable, Equatable {
    let id: Int
    let read: Double?
    let write: Double?
}

struct DiskIOSparkline: View {
    let read: [Double?]
    let write: [Double?]
    let capacity: Int
    @State private var samples: [DiskTimelineSample]
    @State private var nextSampleID: Int
    @State private var layoutBaseCount: Int
    @State private var scrollProgress = 0.0
    @State private var transitionTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(read: [Double?], write: [Double?], capacity: Int) {
        self.read = read
        self.write = write
        self.capacity = max(capacity, 2)
        let initial = Self.makeSamples(read: read, write: write, startingAt: 0)
        _samples = State(initialValue: initial)
        _nextSampleID = State(initialValue: initial.count)
        _layoutBaseCount = State(initialValue: initial.count)
    }

    var body: some View {
        ZStack {
            shape(values: samples.map(\.read), closesToBaseline: true)
                .fill(InstrumentDesign.ColorRole.diskRead.opacity(0.10))
            shape(values: samples.map(\.write), closesToBaseline: true)
                .fill(InstrumentDesign.ColorRole.diskWrite.opacity(0.12))
            shape(values: samples.map(\.read), closesToBaseline: false)
                .stroke(
                    InstrumentDesign.ColorRole.diskRead.opacity(0.88),
                    style: StrokeStyle(
                        lineWidth: InstrumentDesign.Stroke.chart,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            shape(values: samples.map(\.write), closesToBaseline: false)
                .stroke(
                    InstrumentDesign.ColorRole.diskWrite,
                    style: StrokeStyle(
                        lineWidth: InstrumentDesign.Stroke.chart,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
        }
        .clipped()
        .onChange(of: inputSamples) { _, next in updateSamples(next) }
        .onDisappear { transitionTask?.cancel() }
        .accessibilityHidden(true)
    }

    private var inputSamples: [DiskTimelineSample] {
        Self.makeSamples(read: read, write: write, startingAt: 0)
    }

    private var bounds: (lower: Double, upper: Double) {
        let finite = samples
            .flatMap { [$0.read, $0.write] }
            .compactMap { $0 }
            .filter(\.isFinite)
        let lower = min(0, finite.min() ?? 0)
        let high = finite.max() ?? 1
        return (lower, max(high, lower + max(abs(high) * 0.08, 1)))
    }

    private func shape(
        values: [Double?],
        closesToBaseline: Bool
    ) -> StreamingSparklineShape {
        StreamingSparklineShape(
            values: values,
            capacity: capacity,
            baseCount: layoutBaseCount,
            closesToBaseline: closesToBaseline,
            phase: scrollProgress,
            lowerBound: bounds.lower,
            upperBound: bounds.upper
        )
    }

    private func updateSamples(_ next: [DiskTimelineSample]) {
        transitionTask?.cancel()
        let currentValues = samples.map { ($0.read, $0.write) }
        let incomingValues = next.map { ($0.read, $0.write) }
        guard !valuesEqual(currentValues, incomingValues) else { return }

        let isRolling = currentValues.count == incomingValues.count
            && currentValues.count > 1
            && valuesEqual(
                Array(currentValues.dropFirst()),
                Array(incomingValues.dropLast())
            )
        let isGrowing = incomingValues.count == currentValues.count + 1
            && valuesEqual(Array(incomingValues.dropLast()), currentValues)
        guard !reduceMotion, isRolling || isGrowing, let latest = incomingValues.last
        else {
            replaceSamples(with: incomingValues)
            return
        }

        layoutBaseCount = currentValues.count
        withAnimation(.easeInOut(duration: InstrumentDesign.Motion.sampleTransitionDuration)) {
            samples.append(DiskTimelineSample(
                id: nextSampleID,
                read: latest.0,
                write: latest.1
            ))
            scrollProgress = 1
        }
        nextSampleID += 1
        transitionTask = Task { @MainActor in
            try? await Task.sleep(
                for: .seconds(InstrumentDesign.Motion.sampleTransitionDuration)
            )
            guard !Task.isCancelled else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if isRolling { samples.removeFirst() }
                layoutBaseCount = incomingValues.count
                scrollProgress = 0
            }
        }
    }

    private func replaceSamples(with values: [(Double?, Double?)]) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            let currentValues = samples.map { ($0.read, $0.write) }
            if values.count == currentValues.count + 1,
               valuesEqual(Array(values.dropLast()), currentValues) {
                let latest = values[values.count - 1]
                samples.append(DiskTimelineSample(
                    id: nextSampleID,
                    read: latest.0,
                    write: latest.1
                ))
                nextSampleID += 1
            } else {
                var sampleID = nextSampleID
                samples = values.map { value in
                    defer { sampleID += 1 }
                    return DiskTimelineSample(
                        id: sampleID,
                        read: value.0,
                        write: value.1
                    )
                }
                nextSampleID = sampleID
            }
            layoutBaseCount = values.count
            scrollProgress = 0
        }
    }

    private func valuesEqual(
        _ lhs: [(Double?, Double?)],
        _ rhs: [(Double?, Double?)]
    ) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            $0.0.0 == $0.1.0 && $0.0.1 == $0.1.1
        }
    }

    private static func makeSamples(
        read: [Double?],
        write: [Double?],
        startingAt firstID: Int
    ) -> [DiskTimelineSample] {
        let count = max(read.count, write.count)
        return (0..<count).map { index in
            DiskTimelineSample(
                id: firstID + index,
                read: read.indices.contains(index) ? read[index] : nil,
                write: write.indices.contains(index) ? write[index] : nil
            )
        }
    }
}

private struct NetworkTimelineSample: Identifiable, Equatable {
    let id: Int
    let receive: Double?
    let send: Double?
}

private struct StreamingNetworkBarsShape: Shape {
    let values: [Double?]
    let capacity: Int
    let baseCount: Int
    let drawsAboveAxis: Bool
    var phase: Double
    var maximum: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(phase, maximum) }
        set {
            phase = newValue.first
            maximum = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let resolvedCapacity = max(capacity, baseCount, 1)
        let step = rect.width / CGFloat(resolvedCapacity)
        let firstSlot = resolvedCapacity - baseCount
        let gap = min(CGFloat(2.5), step * 0.35)
        let barWidth = max(1, step - gap)
        let axisY = rect.midY
        let availableHeight = rect.height * 0.47

        for (index, value) in values.enumerated() {
            let normalized = min(1, max(0, (value ?? 0) / max(maximum, 1)))
            let height = max(0.75, availableHeight * CGFloat(normalized))
            let x = (CGFloat(firstSlot + index) - CGFloat(phase)) * step + gap / 2
            let y = drawsAboveAxis ? axisY - height : axisY
            path.addRoundedRect(
                in: CGRect(x: x, y: y, width: barWidth, height: height),
                cornerSize: CGSize(width: 1.2, height: 1.2)
            )
        }
        return path
    }
}

struct BidirectionalNetworkBars: View {
    let receive: [Double?]
    let send: [Double?]
    let capacity: Int
    @State private var samples: [NetworkTimelineSample]
    @State private var nextSampleID: Int
    @State private var layoutBaseCount: Int
    @State private var scrollProgress = 0.0
    @State private var transitionTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(receive: [Double?], send: [Double?], capacity: Int? = nil) {
        self.receive = receive
        self.send = send
        self.capacity = max(capacity ?? max(receive.count, send.count), 1)
        let initial = Self.makeSamples(receive: receive, send: send, startingAt: 0)
        _samples = State(initialValue: initial)
        _nextSampleID = State(initialValue: initial.count)
        _layoutBaseCount = State(initialValue: initial.count)
    }

    var body: some View {
        ZStack {
            networkShape(values: samples.map(\.send), drawsAboveAxis: true)
                .fill(InstrumentDesign.ColorRole.upload.opacity(0.68))
            networkShape(values: samples.map(\.receive), drawsAboveAxis: false)
                .fill(InstrumentDesign.ColorRole.read.opacity(0.72))
            Rectangle()
                .fill(Color.secondary.opacity(0.26))
                .frame(height: 0.75)
        }
        .clipped()
        .onChange(of: timelineValues) { _, nextValues in
            updateSamples(nextValues)
        }
        .onDisappear { transitionTask?.cancel() }
        .accessibilityHidden(true)
    }

    private func networkShape(
        values: [Double?],
        drawsAboveAxis: Bool
    ) -> StreamingNetworkBarsShape {
        StreamingNetworkBarsShape(
            values: values,
            capacity: capacity,
            baseCount: layoutBaseCount,
            drawsAboveAxis: drawsAboveAxis,
            phase: scrollProgress,
            maximum: maximum
        )
    }

    private var maximum: Double {
        max(samples.flatMap { [$0.receive, $0.send] }.compactMap { $0 }.max() ?? 1, 1)
    }

    private var timelineValues: [NetworkTimelineSample] {
        Self.makeSamples(receive: receive, send: send, startingAt: 0)
    }

    private func updateSamples(_ nextValues: [NetworkTimelineSample]) {
        transitionTask?.cancel()
        let currentValues = samples.map { ($0.receive, $0.send) }
        let incomingValues = nextValues.map { ($0.receive, $0.send) }
        guard !timelineValuesEqual(currentValues, incomingValues) else { return }

        let exactRolling = currentValues.count == incomingValues.count
            && currentValues.count > 1
            && Array(currentValues.dropFirst()).elementsEqual(
                Array(incomingValues.dropLast()),
                by: { $0.0 == $1.0 && $0.1 == $1.1 }
            )
        // Bucketed network data keeps a fixed count. Its boundaries move with
        // the selected time window, so historical bucket values can change a
        // little even when the timeline has advanced by one bucket. Preserve
        // the physical motion in that case instead of replacing all bars.
        let fixedWindowRolling = currentValues.count == incomingValues.count
            && currentValues.count >= capacity
            && currentValues.count > 1
        let isRolling = exactRolling || fixedWindowRolling
        let isGrowing = incomingValues.count == currentValues.count + 1
            && timelineValuesEqual(Array(incomingValues.dropLast()), currentValues)
        guard !reduceMotion, isRolling || isGrowing, let latest = incomingValues.last
        else {
            replaceSamples(with: incomingValues)
            return
        }

        layoutBaseCount = currentValues.count
        withAnimation(.easeInOut(duration: InstrumentDesign.Motion.sampleTransitionDuration)) {
            samples.append(NetworkTimelineSample(
                id: nextSampleID,
                receive: latest.0,
                send: latest.1
            ))
            scrollProgress = 1
        }
        nextSampleID += 1
        transitionTask = Task { @MainActor in
            try? await Task.sleep(
                for: .seconds(InstrumentDesign.Motion.sampleTransitionDuration)
            )
            guard !Task.isCancelled else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if isRolling { samples.removeFirst() }
                layoutBaseCount = incomingValues.count
                scrollProgress = 0
            }
        }
    }

    private func replaceSamples(with values: [(Double?, Double?)]) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            let currentValues = samples.map { ($0.receive, $0.send) }
            if values.count == currentValues.count + 1,
               timelineValuesEqual(Array(values.dropLast()), currentValues) {
                let latest = values[values.count - 1]
                samples.append(NetworkTimelineSample(
                    id: nextSampleID,
                    receive: latest.0,
                    send: latest.1
                ))
                nextSampleID += 1
            } else {
                var sampleID = nextSampleID
                samples = values.map { value in
                    defer { sampleID += 1 }
                    return NetworkTimelineSample(
                        id: sampleID,
                        receive: value.0,
                        send: value.1
                    )
                }
                nextSampleID = sampleID
            }
            layoutBaseCount = values.count
            scrollProgress = 0
        }
    }

    private func timelineValuesEqual(
        _ lhs: [(Double?, Double?)],
        _ rhs: [(Double?, Double?)]
    ) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            $0.0.0 == $0.1.0 && $0.0.1 == $0.1.1
        }
    }

    private static func makeSamples(
        receive: [Double?],
        send: [Double?],
        startingAt firstID: Int
    ) -> [NetworkTimelineSample] {
        let count = max(receive.count, send.count)
        return (0..<count).map { index in
            NetworkTimelineSample(
                id: firstID + index,
                receive: receive.indices.contains(index) ? receive[index] : nil,
                send: send.indices.contains(index) ? send[index] : nil
            )
        }
    }
}

struct MemoryDonut: View {
    let used: UInt64
    let total: UInt64
    var color = InstrumentDesign.ColorRole.memory
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 8)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color.opacity(0.78), style: StrokeStyle(lineWidth: 8, lineCap: .butt))
                .rotationEffect(.degrees(-90))
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.55),
                    value: fraction
                )
        }
        .accessibilityHidden(true)
    }

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(used) / Double(total))
    }
}

struct SegmentedEnergyMeter: View {
    let fraction: Double
    let color: Color
    var segments = 10
    var threshold: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<segments, id: \.self) { index in
                let segmentEnd = Double(index + 1) / Double(segments)
                RoundedRectangle(cornerRadius: 2)
                    .fill(fillColor(segmentEnd))
                    .overlay {
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
                    }
            }
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.48),
            value: fraction
        )
        .accessibilityHidden(true)
    }

    private func fillColor(_ segmentEnd: Double) -> Color {
        guard segmentEnd <= max(0, min(1, fraction)) else {
            return Color.secondary.opacity(0.15)
        }
        if let threshold, segmentEnd > threshold {
            return InstrumentDesign.ColorRole.warning.opacity(0.84)
        }
        return color.opacity(0.74)
    }
}

struct GlassSegmentedControl<Selection: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Selection
    @ViewBuilder let content: () -> Content

    init(
        _ title: String,
        selection: Binding<Selection>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        _selection = selection
        self.content = content
    }

    var body: some View {
        Picker(L10n.text(title), selection: $selection) {
            content()
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .tint(Color.secondary.opacity(0.72))
        .accentColor(Color.secondary.opacity(0.72))
        .padding(2)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.48),
            in: RoundedRectangle(cornerRadius: InstrumentDesign.Radius.control)
        )
        .overlay {
            RoundedRectangle(cornerRadius: InstrumentDesign.Radius.control)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.6)
        }
        .accessibilityLabel(L10n.text(title))
    }
}

enum AppActionButtonKind {
    case primary
    case secondary
    case destructive
}

enum AppActionButtonSize {
    case compact
    case regular
    case large

    var minimumHeight: CGFloat {
        switch self {
        case .compact: 30
        case .regular: 34
        case .large: 38
        }
    }

    fileprivate var horizontalPadding: CGFloat {
        switch self {
        case .compact: 10
        case .regular: 13
        case .large: 16
        }
    }

    fileprivate var font: Font {
        switch self {
        case .compact: .caption.weight(.semibold)
        case .regular: .callout.weight(.semibold)
        case .large: .body.weight(.semibold)
        }
    }

    fileprivate var cornerRadius: CGFloat {
        self == .compact ? 6 : 7
    }
}

struct AppActionButtonStyle: ButtonStyle {
    let kind: AppActionButtonKind
    var size: AppActionButtonSize = .regular

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        AppActionButtonBody(
            label: configuration.label,
            kind: kind,
            size: size,
            isEnabled: isEnabled,
            isPressed: configuration.isPressed
        )
    }
}

private struct AppActionButtonBody<Label: View>: View {
    let label: Label
    let kind: AppActionButtonKind
    let size: AppActionButtonSize
    let isEnabled: Bool
    let isPressed: Bool

    @State private var isHovering = false

    var body: some View {
        label
            .font(size.font)
            .lineLimit(1)
            .padding(.horizontal, size.horizontalPadding)
            .frame(minHeight: size.minimumHeight)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: size.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: size.cornerRadius)
                    .stroke(borderColor, lineWidth: kind == .secondary ? 0.75 : 0.5)
            }
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: size.cornerRadius)
                    .stroke(Color.white.opacity(kind == .secondary ? 0.07 : 0.16), lineWidth: 0.5)
                    .mask(Rectangle().frame(height: 10).frame(maxHeight: .infinity, alignment: .top))
            }
            .shadow(
                color: shadowColor,
                radius: kind == .secondary ? 0 : 2,
                y: kind == .secondary ? 0 : 1
            )
            .contentShape(RoundedRectangle(cornerRadius: size.cornerRadius))
            .opacity(isEnabled ? 1 : 0.46)
            .scaleEffect(isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.1), value: isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }

    private var foregroundColor: Color {
        switch kind {
        case .primary, .destructive: .white
        case .secondary: .primary
        }
    }

    private var backgroundColor: Color {
        switch kind {
        case .primary:
            return Color.accentColor.opacity(isPressed ? 0.78 : isHovering ? 0.92 : 0.86)
        case .secondary:
            if isPressed { return Color.primary.opacity(0.13) }
            if isHovering { return Color.primary.opacity(0.09) }
            return Color(nsColor: .controlBackgroundColor).opacity(0.92)
        case .destructive:
            return Color.red.opacity(isPressed ? 0.78 : isHovering ? 0.9 : 1)
        }
    }

    private var borderColor: Color {
        switch kind {
        case .primary: .white.opacity(0.18)
        case .secondary: Color(nsColor: .separatorColor).opacity(0.9)
        case .destructive: .white.opacity(0.2)
        }
    }

    private var shadowColor: Color {
        switch kind {
        case .primary: Color.accentColor.opacity(0.2)
        case .secondary: .clear
        case .destructive: Color.red.opacity(0.2)
        }
    }
}

struct AppIconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var isFramed = true

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        AppIconButtonBody(
            label: configuration.label,
            size: size,
            isFramed: isFramed,
            isEnabled: isEnabled,
            isPressed: configuration.isPressed
        )
    }
}

private struct AppIconButtonBody<Label: View>: View {
    let label: Label
    let size: CGFloat
    let isFramed: Bool
    let isEnabled: Bool
    let isPressed: Bool

    @State private var isHovering = false

    var body: some View {
        label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if isFramed {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.72), lineWidth: 0.5)
                }
            }
            .overlay(alignment: .top) {
                if isFramed {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                        .mask(Rectangle().frame(height: 8).frame(maxHeight: .infinity, alignment: .top))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }

    private var backgroundColor: Color {
        guard isFramed else { return isHovering ? Color.primary.opacity(0.07) : .clear }
        if isPressed { return Color.primary.opacity(0.14) }
        if isHovering { return Color.primary.opacity(0.1) }
        return Color(nsColor: .controlBackgroundColor).opacity(0.78)
    }
}

struct SectionHeading<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let trailing: () -> Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(title))
                    .font(.headline)
                if let subtitle {
                    Text(L10n.text(subtitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing()
        }
    }
}

/// A compact instrument-style page header shared by secondary destinations.
/// The header keeps the title, context and controls on one stable glass plane
/// so switching pages does not produce a white flash or a layout jump.
struct InstrumentPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let symbol: String
    @ViewBuilder let trailing: () -> Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        symbol: String,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(InstrumentDesign.ColorRole.cpu)
                .frame(width: 34, height: 34)
                .background(
                    InstrumentDesign.ColorRole.cpu.opacity(0.11),
                    in: RoundedRectangle(cornerRadius: InstrumentDesign.Radius.icon)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: InstrumentDesign.Radius.icon)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(title))
                    .font(.system(size: 19, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let subtitle {
                    Text(L10n.text(subtitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
            }

            Spacer(minLength: 10)
            trailing()
        }
        .padding(.horizontal, InstrumentDesign.Spacing.page)
        .padding(.vertical, 12)
        .glassSurface(padding: 0)
        .accessibilityElement(children: .contain)
    }
}

extension InstrumentPageHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, symbol: String) {
        self.init(title, subtitle: subtitle, symbol: symbol) { EmptyView() }
    }
}

extension SectionHeading where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

struct MetricValue: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(title))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.text(value))
                    .font(.system(.body, design: .monospaced, weight: .semibold))
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct EvidenceLabel: View {
    let text: String
    let symbol: String
    var color: Color = .secondary

    var body: some View {
        Label(L10n.text(text), systemImage: symbol)
            .font(.caption)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

struct NetworkMetricValue: View {
    let download: Double
    let upload: Double
    let isAvailable: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "network")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 22, height: 22)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("网络 · 最近 5 秒"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isAvailable {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            networkRate(download, symbol: "arrow.down", color: .green)
                            networkRate(upload, symbol: "arrow.up", color: .indigo)
                        }
                        .fixedSize(horizontal: true, vertical: false)

                        VStack(alignment: .leading, spacing: 1) {
                            networkRate(download, symbol: "arrow.down", color: .green)
                            networkRate(upload, symbol: "arrow.up", color: .indigo)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                } else {
                    Text(L10n.text("采样缺口"))
                        .font(.callout.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func networkRate(_ value: Double, symbol: String, color: Color) -> some View {
        Label(ByteRateFormatter.rate(value), systemImage: symbol)
            .font(.system(.callout, design: .monospaced, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
    }
}
