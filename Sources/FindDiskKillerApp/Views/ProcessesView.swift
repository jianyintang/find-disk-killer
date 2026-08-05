import FindDiskKillerCore
import SwiftUI

struct ProcessesView: View {
    let store: MonitorStore
    @Binding var searchText: String
    let processDetailWindows: ProcessDetailWindowCoordinator
    @Environment(\.openWindow) private var openWindow
    @State private var selection: ProcessActivity.ID?
    @State private var processHoverCoordinator = ProcessHoverCoordinator()

    var body: some View {
        VStack(spacing: 0) {
            ProcessesPageHeader(
                selectedRange: Bindable(store).selectedRange,
                searchText: $searchText
            )

            LiveProcessesTable(
                store: store,
                searchText: searchText,
                selectedProcessID: selection,
                hoverCoordinator: processHoverCoordinator,
                onSelect: presentProcess
            )
            .padding(.top, InstrumentDesign.Spacing.related)
            .padding(.horizontal, InstrumentDesign.Spacing.page)
            .padding(.bottom, InstrumentDesign.Spacing.page)
        }
    }

    static func filter(_ processes: [ProcessActivity], query: String) -> [ProcessActivity] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return processes }
        return processes.filter {
            matches(name: $0.name, executablePath: $0.executablePath, query: normalizedQuery)
        }
    }

    static func matches(name: String, executablePath: String, query: String) -> Bool {
        name.localizedCaseInsensitiveContains(query)
            || executablePath.localizedCaseInsensitiveContains(query)
    }

    private func presentProcess(_ process: ProcessActivity) {
        selection = process.id
        processHoverCoordinator.clearForSelection()
        let presentation = ProcessDetailPresentation(process: process, updatesLive: true)
        processDetailWindows.present(presentation)
        openWindow(id: "process-detail", value: process.id)
        processDetailWindows.activate(presentation)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            if selection == process.id { selection = nil }
        }
    }

}

struct ProcessesPageHeader: View {
    @Binding var selectedRange: SampleRange
    @Binding var searchText: String

    var body: some View {
        InstrumentPageHeader("应用") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    rangeControl(width: 260)
                    processSearchField(width: 240)
                    EvidenceLabel(
                        text: "I/O · CPU · 网络 · 当前用户可见",
                        symbol: "person.crop.circle.badge.checkmark"
                    )
                }

                HStack(spacing: 10) {
                    rangeControl(width: 250)
                    processSearchField(width: 220)
                }

                HStack(spacing: 8) {
                    rangeControl(width: 210)
                    processSearchField(width: 170)
                }
            }
        }
    }

    private func rangeControl(width: CGFloat) -> some View {
        GlassSegmentedControl("时间范围", selection: $selectedRange) {
            ForEach(SampleRange.allCases) { range in
                Text(range.localizedTitle).tag(range)
            }
        }
        .frame(width: width)
        .accessibilityLabel(L10n.text("时间范围"))
    }

    private func processSearchField(width: CGFloat) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(L10n.text("搜索应用或进程"), text: $searchText)
                .textFieldStyle(.plain)
                .lineLimit(1)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L10n.text("清除搜索"))
                .accessibilityLabel(L10n.text("清除搜索"))
            }
        }
        .padding(.horizontal, 9)
        .frame(width: width, height: 28)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct LiveProcessesTable: View {
    let store: MonitorStore
    let searchText: String
    let selectedProcessID: ProcessActivity.ID?
    let hoverCoordinator: ProcessHoverCoordinator
    let onSelect: (ProcessActivity) -> Void

    var body: some View {
        ProcessTable(
            processes: ProcessesView.filter(store.processes, query: searchText),
            contentRevision: ProcessTableRevision(
                sample: store.processSummaryRevision,
                query: searchText
            ),
            selectedProcessID: selectedProcessID,
            pageSize: ProcessTable.appsPageSize,
            scrollAxes: [.horizontal, .vertical],
            hoverCoordinator: hoverCoordinator,
            onSelect: onSelect,
            isLoading: store.lastUpdatedAt == nil && searchText.isEmpty,
            emptyStateTitle: searchText.isEmpty ? nil : L10n.text("未找到匹配的应用"),
            emptyStateSymbol: searchText.isEmpty ? "waveform.path.ecg" : "magnifyingglass"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassSurface(padding: 0)
    }
}
