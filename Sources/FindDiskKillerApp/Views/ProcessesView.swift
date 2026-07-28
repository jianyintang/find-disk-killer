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
            HStack {
                Picker(L10n.text("时间范围"), selection: Bindable(store).selectedRange) {
                    ForEach(SampleRange.allCases) { range in
                        Text(range.localizedTitle).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Spacer()
                EvidenceLabel(
                    text: "I/O · CPU · 网络 · 当前用户可见",
                    symbol: "person.crop.circle.badge.checkmark"
                )
            }
            .padding(16)

            Divider()

            ProcessTable(
                processes: filteredProcesses,
                selectedProcessID: selection,
                scrollAxes: [.horizontal, .vertical],
                hoverCoordinator: processHoverCoordinator,
                onSelect: presentProcess,
                isLoading: store.lastUpdatedAt == nil && searchText.isEmpty
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .searchable(text: $searchText, prompt: L10n.text("搜索应用或进程"))
    }

    private var filteredProcesses: [ProcessActivity] {
        let source = store.processes
        guard !searchText.isEmpty else { return source }
        return source.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.executablePath.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func presentProcess(_ process: ProcessActivity) {
        selection = process.id
        processHoverCoordinator.clearForSelection()
        processDetailWindows.present(ProcessDetailPresentation(process: process, updatesLive: true))
        openWindow(id: "process-detail", value: process.id)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            if selection == process.id { selection = nil }
        }
    }

}
