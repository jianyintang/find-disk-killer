import AppKit
import FindDiskKillerCore
import SwiftUI

struct HistoryApplicationTable: View {
    let applications: [HistoryApplicationReport]
    var isLoading = false

    @State private var sortMetric: ApplicationHistorySortMetric = .write
    @State private var ascending = false
    @State private var selectedApplicationID: HistoryApplicationReport.ID?
    @State private var hoveredApplicationID: HistoryApplicationReport.ID?
    @FocusState private var tableHasFocus: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideLayout
                .frame(minWidth: 920)
            regularLayout
                .frame(minWidth: 700)
            compactLayout
        }
        .onChange(of: applications, initial: true) { _, newValue in
            guard !newValue.isEmpty else {
                selectedApplicationID = nil
                return
            }
            ensureVisibleSelection()
        }
        .onChange(of: sortMetric) { _, _ in
            ensureVisibleSelection()
        }
        .onChange(of: ascending) { _, _ in
            ensureVisibleSelection()
        }
        .redacted(reason: isLoading ? .placeholder : [])
        .allowsHitTesting(!isLoading)
        .accessibilityHidden(isLoading)
    }

    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 16) {
            applicationRows(compact: false)
            Divider()
            applicationDetail
                .frame(width: 224, alignment: .topLeading)
        }
    }

    private var regularLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            applicationRows(compact: false)
            Divider().padding(.top, 10)
            applicationDetail.padding(.top, 14)
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            compactSortControls
                .padding(.bottom, 8)
            applicationRows(compact: true)
            Divider().padding(.top, 10)
            applicationDetail.padding(.top, 14)
        }
    }

    private func applicationRows(compact: Bool) -> some View {
        VStack(spacing: 0) {
            if compact {
                compactHeader
            } else {
                fullHeader
            }
            Divider()

            if isLoading {
                ForEach(0..<5, id: \.self) { index in
                    loadingApplicationRow(rank: index + 1, compact: compact)
                        .frame(height: 44)
                    if index < 4 {
                        Divider().padding(.leading, 40)
                    }
                }
            } else {
                ForEach(Array(sortedApplications.enumerated()), id: \.element.id) { index, application in
                    Button {
                        selectedApplicationID = application.id
                        tableHasFocus = true
                    } label: {
                        applicationRow(application, rank: index + 1, compact: compact)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(rowBackground(for: application.id))
                    .overlay(alignment: .leading) {
                        if selectedApplicationID == application.id {
                            Rectangle()
                                .fill(Color.accentColor.opacity(tableHasFocus ? 0.9 : 0.55))
                                .frame(width: 2)
                        }
                    }
                    .onHover { isHovered in
                        hoveredApplicationID = isHovered ? application.id : nil
                    }
                    .accessibilityLabel(displayName(for: application))
                    .accessibilityValue(accessibilitySummary(for: application, rank: index + 1))
                    .accessibilityHint(L10n.text("按下打开详情"))

                    if index < sortedApplications.count - 1 {
                        Divider().padding(.leading, 40)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($tableHasFocus)
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
    }

    private var fullHeader: some View {
        HStack(spacing: 8) {
            Text("#")
                .frame(width: 32, alignment: .trailing)
            Text(L10n.text("应用"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.text("写入占比"))
                .frame(width: 105, alignment: .leading)
            sortButton(.write, width: 92)
            sortButton(.read, width: 92)
            sortButton(.cpu, width: 86)
            sortButton(.network, width: 96)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private var compactHeader: some View {
        HStack(spacing: 8) {
            Text("#")
                .frame(width: 32, alignment: .trailing)
            Text(L10n.text("应用"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.text("写入占比"))
                .frame(width: 105, alignment: .leading)
            Text(sortMetric.title)
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private var compactSortControls: some View {
        HStack(spacing: 8) {
            Text(L10n.text("排序"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                ForEach(ApplicationHistorySortMetric.allCases) { metric in
                    Button {
                        sortMetric = metric
                        ascending = false
                    } label: {
                        Label(metric.title, systemImage: sortMetric == metric ? "checkmark" : metric.symbol)
                    }
                }
            } label: {
                Label(sortMetric.title, systemImage: sortMetric.symbol)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                ascending.toggle()
            } label: {
                Image(systemName: ascending ? "arrow.up" : "arrow.down")
            }
            .buttonStyle(.borderless)
            .help(L10n.format("按%@排序", sortMetric.title))
            .accessibilityLabel(L10n.format("按%@排序", sortMetric.title))

            Spacer()
        }
    }

    private func sortButton(_ metric: ApplicationHistorySortMetric, width: CGFloat) -> some View {
        Button {
            if sortMetric == metric {
                ascending.toggle()
            } else {
                sortMetric = metric
                ascending = false
            }
        } label: {
            HStack(spacing: 3) {
                Spacer(minLength: 0)
                Text(metric.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                if sortMetric == metric {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .frame(width: width, height: 34, alignment: .trailing)
            .foregroundStyle(sortMetric == metric ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.format("按%@排序", metric.title))
        .accessibilityLabel(L10n.format("按%@排序", metric.title))
    }

    private func applicationRow(
        _ application: HistoryApplicationReport,
        rank: Int,
        compact: Bool
    ) -> some View {
        HStack(spacing: 8) {
            rankLabel(rank)
            applicationIdentity(application)
            writeShareBar(application)
            metricText(
                compact
                    ? sortMetric.formattedValue(for: application)
                    : formattedMetric(.write, for: application),
                width: 92
            )

            if !compact {
                metricText(formattedMetric(.read, for: application), width: 92)
                metricText(formattedMetric(.cpu, for: application), width: 86)
                metricText(formattedNetwork(for: application), width: 96)
            }
        }
        .padding(.horizontal, 8)
        .font(.callout)
    }

    private func loadingApplicationRow(rank: Int, compact: Bool) -> some View {
        HStack(spacing: 8) {
            rankLabel(rank)
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 26, height: 26)
                Text("Application name")
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 7) {
                Capsule().fill(.quaternary).frame(width: 50, height: 4)
                Text("00%").frame(width: 38, alignment: .trailing)
            }
            .frame(width: 105, alignment: .leading)

            metricText("000 GB", width: 92)
            if !compact {
                metricText("000 GB", width: 92)
                metricText("00小时", width: 86)
                metricText("000 GB", width: 96)
            }
        }
        .padding(.horizontal, 8)
        .font(.callout)
    }

    private func rankLabel(_ rank: Int) -> some View {
        Text("#\(rank)")
            .font(.caption.monospacedDigit().weight(rank <= 3 ? .semibold : .regular))
            .foregroundStyle(rank <= 3 ? Color.primary : Color.secondary)
            .frame(width: 32, alignment: .trailing)
    }

    private func applicationIdentity(_ application: HistoryApplicationReport) -> some View {
        HStack(spacing: 9) {
            HistoryApplicationIcon(
                identity: application.id
            )

            Text(displayName(for: application))
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(displayName(for: application))
    }

    @ViewBuilder
    private func writeShareBar(_ application: HistoryApplicationReport) -> some View {
        if application.unavailableMetrics.contains(.write) {
            HStack(spacing: 7) {
                Capsule().fill(Color.secondary.opacity(0.14))
                    .frame(width: 50, height: 4)
                Text(L10n.text("不可用"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            .frame(width: 105, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("写入占比"))
            .accessibilityValue(L10n.text("不可用"))
        } else {
            let share = writeShare(for: application)
            HStack(spacing: 7) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.14))
                    Capsule().fill(identityColor(for: application).opacity(0.82))
                        .frame(width: max(2, 50 * share))
                }
                .frame(width: 50, height: 4)

                Text(share, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            .frame(width: 105, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("写入占比"))
            .accessibilityValue(share.formatted(.percent.precision(.fractionLength(0))))
        }
    }

    private func metricText(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.callout.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.74)
            .frame(width: width, alignment: .trailing)
    }

    @ViewBuilder
    private var applicationDetail: some View {
        if isLoading {
            loadingApplicationDetail
        } else if let selectedApplication {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    HistoryApplicationIcon(
                        identity: selectedApplication.id,
                        size: 32
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName(for: selectedApplication))
                            .font(.headline)
                            .lineLimit(1)
                        if let selectedRank {
                            Text("#\(selectedRank)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if selectedApplication.id == "other" {
                    otherAggregationExplanation
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        applicationDetailMetrics(selectedApplication)
                    }
                    .frame(minWidth: 620, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        applicationDetailMetrics(selectedApplication)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    private var loadingApplicationDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(.quaternary)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Application name")
                        .font(.headline)
                        .lineLimit(1)
                    Text("#1")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    loadingDetailMetrics
                }
                .frame(minWidth: 620, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    loadingDetailMetrics
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var loadingDetailMetrics: some View {
        detailMetric(L10n.text("写入"), "000 GB", "square.and.arrow.down")
        detailMetric(L10n.text("读取"), "000 GB", "square.and.arrow.up")
        detailMetric("CPU", "00小时", "cpu")
        detailMetric(L10n.text("网络"), "000 GB", "network")
        detailMetric(L10n.text("写入占比"), "00%", "chart.bar.fill")
    }

    private func detailMetric(_ title: String, _ value: String, _ symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.monospacedDigit().weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func applicationDetailMetrics(_ application: HistoryApplicationReport) -> some View {
        detailMetric(L10n.text("写入"), formattedMetric(.write, for: application), "square.and.arrow.down")
        detailMetric(L10n.text("读取"), formattedMetric(.read, for: application), "square.and.arrow.up")
        detailMetric("CPU", formattedMetric(.cpu, for: application), "cpu")
        detailMetric(L10n.text("网络"), formattedNetwork(for: application), "network")
        detailMetric(
            L10n.text("写入占比"),
            application.unavailableMetrics.contains(.write)
                ? L10n.text("不可用")
                : writeShare(for: application).formatted(.percent.precision(.fractionLength(0))),
            "chart.bar.fill"
        )
    }

    private var sortedApplications: [HistoryApplicationReport] {
        Array(applications.sorted { lhs, rhs in
            let lhsAvailable = sortMetric.isAvailable(for: lhs)
            let rhsAvailable = sortMetric.isAvailable(for: rhs)
            if lhsAvailable != rhsAvailable { return lhsAvailable }
            let lhsValue = sortMetric.value(for: lhs)
            let rhsValue = sortMetric.value(for: rhs)
            if lhsValue != rhsValue {
                return ascending ? lhsValue < rhsValue : lhsValue > rhsValue
            }
            let comparison = displayName(for: lhs).localizedStandardCompare(displayName(for: rhs))
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.id < rhs.id
        }.prefix(20))
    }

    private var selectedApplication: HistoryApplicationReport? {
        guard let selectedApplicationID else { return sortedApplications.first }
        return applications.first { $0.id == selectedApplicationID }
    }

    private var selectedRank: Int? {
        guard let selectedApplicationID else { return nil }
        return sortedApplications.firstIndex { $0.id == selectedApplicationID }.map { $0 + 1 }
    }

    private var totalWriteBytes: Double {
        applications.reduce(0) { $0 + Double($1.writeBytes) }
    }

    private func writeShare(for application: HistoryApplicationReport) -> Double {
        guard totalWriteBytes > 0 else { return 0 }
        return min(1, Double(application.writeBytes) / totalWriteBytes)
    }

    private func networkBytes(for application: HistoryApplicationReport) -> UInt64 {
        application.networkReceiveBytes.addingClamped(application.networkSendBytes)
    }

    private func formattedMetric(
        _ metric: HistoryApplicationMetricSet,
        for application: HistoryApplicationReport
    ) -> String {
        guard !application.unavailableMetrics.contains(metric) else {
            return L10n.text("不可用")
        }
        if metric == .write { return ByteRateFormatter.bytes(application.writeBytes) }
        if metric == .read { return ByteRateFormatter.bytes(application.readBytes) }
        return cpuDuration(for: application)
    }

    private func formattedNetwork(for application: HistoryApplicationReport) -> String {
        let unavailable = application.unavailableMetrics
        guard !unavailable.contains(.networkReceive), !unavailable.contains(.networkSend) else {
            return L10n.text("不可用")
        }
        return ByteRateFormatter.bytes(networkBytes(for: application))
    }

    private func cpuDuration(for application: HistoryApplicationReport) -> String {
        Duration.seconds(Double(application.cpuTimeNanoseconds) / 1_000_000_000)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }

    private func displayName(for application: HistoryApplicationReport) -> String {
        application.id == "other" ? L10n.text("其他应用汇总") : application.name
    }

    private var otherAggregationExplanation: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            Text(L10n.format(
                "旧版本或单日超过 %d 个稳定应用身份时，超出部分会汇总于此。资源总量仍完整保留，但无法再拆分到单个应用。",
                HistoryApplicationAggregationPolicy.dailyLedgerIdentityLimit
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func identityColor(for application: HistoryApplicationReport) -> Color {
        let palette: [Color] = [.blue, .teal, .orange, .indigo, .green, .pink]
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in application.name.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return palette[Int(hash % UInt64(palette.count))]
    }

    private func rowBackground(for id: HistoryApplicationReport.ID) -> Color {
        if selectedApplicationID == id { return Color.accentColor.opacity(0.12) }
        if hoveredApplicationID == id { return Color.primary.opacity(0.045) }
        return .clear
    }

    private func moveSelection(by offset: Int) {
        guard !sortedApplications.isEmpty else { return }
        let currentIndex = selectedApplicationID
            .flatMap { selectedID in sortedApplications.firstIndex { $0.id == selectedID } }
            ?? 0
        let nextIndex = min(max(0, currentIndex + offset), sortedApplications.count - 1)
        selectedApplicationID = sortedApplications[nextIndex].id
    }

    private func ensureVisibleSelection() {
        guard !sortedApplications.isEmpty else {
            selectedApplicationID = nil
            return
        }
        if !sortedApplications.contains(where: { $0.id == selectedApplicationID }) {
            selectedApplicationID = sortedApplications.first?.id
        }
    }

    private func accessibilitySummary(
        for application: HistoryApplicationReport,
        rank: Int
    ) -> String {
        let writeShare = application.unavailableMetrics.contains(.write)
            ? L10n.text("不可用")
            : writeShare(for: application).formatted(
                .percent.precision(.fractionLength(0))
            )
        return [
            "#\(rank)",
            application.id == "other" ? L10n.text("这是超过历史身份容量的应用汇总，资源总量仍完整保留") : nil,
            "\(L10n.text("写入")) \(formattedMetric(.write, for: application))",
            "\(L10n.text("读取")) \(formattedMetric(.read, for: application))",
            "CPU \(formattedMetric(.cpu, for: application))",
            "\(L10n.text("网络")) \(formattedNetwork(for: application))",
            "\(L10n.text("写入占比")) \(writeShare)"
        ].compactMap { $0 }.joined(separator: ", ")
    }
}

private struct HistoryApplicationIcon: View {
    let identity: String
    var size: CGFloat = 26
    @State private var applicationIcon: NSImage?

    var body: some View {
        Group {
            if let image = applicationIcon {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: identity == "other" ? "ellipsis" : "terminal")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.2)
                    .foregroundStyle(.secondary)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: identity) {
            applicationIcon = resolveApplicationIcon()
        }
    }

    private func resolveApplicationIcon() -> NSImage? {
        guard identity.hasPrefix("bundle:") else { return nil }
        let bundleIdentifier = String(identity.dropFirst("bundle:".count))
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

private enum ApplicationHistorySortMetric: String, CaseIterable, Identifiable {
    case write
    case read
    case cpu
    case network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .write: L10n.text("写入")
        case .read: L10n.text("读取")
        case .cpu: "CPU"
        case .network: L10n.text("网络")
        }
    }

    var symbol: String {
        switch self {
        case .write: "square.and.arrow.down"
        case .read: "square.and.arrow.up"
        case .cpu: "cpu"
        case .network: "network"
        }
    }

    func value(for application: HistoryApplicationReport) -> UInt64 {
        switch self {
        case .write:
            application.writeBytes
        case .read:
            application.readBytes
        case .cpu:
            application.cpuTimeNanoseconds
        case .network:
            application.networkReceiveBytes.addingClamped(application.networkSendBytes)
        }
    }

    func isAvailable(for application: HistoryApplicationReport) -> Bool {
        switch self {
        case .write:
            !application.unavailableMetrics.contains(.write)
        case .read:
            !application.unavailableMetrics.contains(.read)
        case .cpu:
            !application.unavailableMetrics.contains(.cpu)
        case .network:
            !application.unavailableMetrics.contains(.networkReceive)
                && !application.unavailableMetrics.contains(.networkSend)
        }
    }

    func formattedValue(for application: HistoryApplicationReport) -> String {
        guard isAvailable(for: application) else { return L10n.text("不可用") }
        switch self {
        case .write:
            return ByteRateFormatter.bytes(application.writeBytes)
        case .read:
            return ByteRateFormatter.bytes(application.readBytes)
        case .cpu:
            return Duration.seconds(Double(application.cpuTimeNanoseconds) / 1_000_000_000)
                .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
        case .network:
            return ByteRateFormatter.bytes(
                application.networkReceiveBytes.addingClamped(application.networkSendBytes)
            )
        }
    }
}

private extension UInt64 {
    func addingClamped(_ other: UInt64) -> UInt64 {
        let result = addingReportingOverflow(other)
        return result.overflow ? .max : result.partialValue
    }
}
