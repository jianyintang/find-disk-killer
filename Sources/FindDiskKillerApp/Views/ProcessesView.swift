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
            InstrumentPageHeader(
                "应用",
                symbol: "square.stack.3d.up"
            )
            processesToolbar
                .padding(.horizontal, InstrumentDesign.Spacing.page)
                .padding(.vertical, InstrumentDesign.Spacing.related)
                .glassSurface(padding: 10)
                .padding(.horizontal, InstrumentDesign.Spacing.page)

            LiveProcessesTable(
                store: store,
                searchText: searchText,
                selectedProcessID: selection,
                hoverCoordinator: processHoverCoordinator,
                onSelect: presentProcess
            )
            .padding(.horizontal, InstrumentDesign.Spacing.page)
            .padding(.bottom, InstrumentDesign.Spacing.page)
        }
    }

    private var processesToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                rangeControl(showsLabel: true)
                Spacer(minLength: 16)
                processSearchField
                EvidenceLabel(
                    text: "I/O · CPU · 网络 · 当前用户可见",
                    symbol: "person.crop.circle.badge.checkmark"
                )
            }

            HStack(spacing: 12) {
                rangeControl(showsLabel: false)
                Spacer(minLength: 8)
                processSearchField
            }
        }
        .frame(height: 32)
    }

    private func rangeControl(showsLabel: Bool) -> some View {
        HStack(spacing: 10) {
            if showsLabel {
                Text(L10n.text("时间范围"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            GlassSegmentedControl(
                "时间范围",
                selection: Bindable(store).selectedRange
            ) {
                ForEach(SampleRange.allCases) { range in
                    Text(range.localizedTitle).tag(range)
                }
            }
            .frame(width: 260)
            .accessibilityLabel(L10n.text("时间范围"))
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var processSearchField: some View {
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
        .frame(width: 240, height: 28)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
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

private struct LiveProcessesTable: View {
    let store: MonitorStore
    let searchText: String
    let selectedProcessID: ProcessActivity.ID?
    let hoverCoordinator: ProcessHoverCoordinator
    let onSelect: (ProcessActivity) -> Void

    var body: some View {
        ProcessTable(
            processes: ProcessesView.filter(store.processes, query: searchText),
            selectedProcessID: selectedProcessID,
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
