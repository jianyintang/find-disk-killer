import Testing
import FindDiskKillerCore
@testable import FindDiskKillerApp

@Test func overviewDiskLayoutFitsOneInternalVolumeWithoutAnEmptyGap() {
    let layout = OverviewDiskLayout(volumeCount: 1)

    #expect(layout.rowHeight == OverviewDiskLayout.singleVolumeRowHeight)
    #expect(layout.volumeViewportHeight == OverviewDiskLayout.singleVolumeRowHeight)
    #expect(abs(layout.contentHeight
        - OverviewDiskLayout.singleVolumeRowHeight
        - OverviewDiskLayout.summaryHeight) < 0.001)
    #expect(!layout.isScrollable)
}

@Test func overviewDiskLayoutGrowsForSeveralExternalVolumes() {
    let layout = OverviewDiskLayout(volumeCount: 4)

    #expect(layout.visibleRowCount == 4)
    #expect(abs(layout.volumeViewportHeight
        - 4 * OverviewDiskLayout.standardVolumeRowHeight) < 0.001)
    #expect(abs(layout.contentHeight
        - layout.volumeViewportHeight
        - OverviewDiskLayout.summaryHeight) < 0.001)
    #expect(!layout.isScrollable)
}

@Test func overviewDiskLayoutCapsManyVolumesAndEnablesLocalScrolling() {
    let fiveVolumes = OverviewDiskLayout(volumeCount: 5)
    let eightVolumes = OverviewDiskLayout(volumeCount: 8)

    #expect(eightVolumes.visibleRowCount == OverviewDiskLayout.maximumVisibleVolumeRows)
    #expect(eightVolumes.volumeViewportHeight == fiveVolumes.volumeViewportHeight)
    #expect(eightVolumes.contentHeight == fiveVolumes.contentHeight)
    #expect(eightVolumes.isScrollable)
}

@Test func processTableKeepsBaseWidthsWhenTheContainerIsNarrow() {
    let base = ProcessColumnWidths.defaults

    let resolved = base.adapted(to: base.tableWidth - 180)

    #expect(resolved == base)
}

@Test func processTableDistributesWideSpaceWithoutOverstretchingTheApplicationColumn() {
    let base = ProcessColumnWidths.defaults
    let availableWidth = 1_520.0

    let resolved = base.adapted(to: availableWidth)

    #expect(abs(resolved.tableWidth - availableWidth) < 0.001)
    #expect(resolved[.application] <= ProcessColumn.adaptiveApplicationUpperBound)
    #expect(resolved[.application] > base[.application])
    #expect(resolved[.cpu] > base[.cpu])
    #expect(resolved[.networkDownload] > base[.networkDownload])
    #expect(resolved[.networkDownload] - base[.networkDownload]
        > resolved[.cpu] - base[.cpu])
}

@Test func processTableNeverShrinksAUserExpandedApplicationColumn() {
    var base = ProcessColumnWidths.defaults
    base[.application] = 400

    let resolved = base.adapted(to: 1_600)

    #expect(resolved[.application] >= 400)
    #expect(abs(resolved.tableWidth - 1_600) < 0.001)
}

@MainActor
@Test func activeAppsDefaultSortIsCurrentWriteDescending() {
    #expect(ProcessTable.defaultSortKey == .writeCurrent)
    #expect(!ProcessTable.defaultSortAscending)
}

@MainActor
@Test func processSearchMatchesLocalizedNameAndExecutablePathWithoutChangingLayoutState() {
    #expect(ProcessesView.matches(
        name: "Codex",
        executablePath: "/Applications/Codex.app/Contents/MacOS/Codex",
        query: "codex"
    ))
    #expect(ProcessesView.matches(
        name: "Finder",
        executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
        query: "CoreServices"
    ))
    #expect(!ProcessesView.matches(
        name: "Finder",
        executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
        query: "Codex"
    ))
}

@MainActor
@Test func activeAppsTopTwelveAlwaysIncludesTheSystemLayer() {
    var rows: [ActiveAppRow] = []
    for index in 0..<15 {
        let metric = Double(100 - index)
        let activity = SystemLayerActivity(
            id: "ordinary-\(index)",
            currentCPUPercent: metric,
            totalWriteBytes: UInt64(100 - index),
            currentWriteBytesPerSecond: metric,
            peakWriteBytesPerSecond: metric,
            averageNetworkReceiveBytesPerSecond: metric,
            averageNetworkSendBytesPerSecond: metric
        )
        rows.append(.systemLayer(activity))
    }
    rows.append(.systemLayer(SystemLayerActivity(
        currentCPUPercent: 0,
        totalWriteBytes: 0,
        currentWriteBytesPerSecond: 0,
        peakWriteBytesPerSecond: 0,
        averageNetworkReceiveBytesPerSecond: 0,
        averageNetworkSendBytesPerSecond: 0
    )))

    let visible = ProcessTable.visibleRows(
        rows, limit: 12, sortKey: .cpuCurrent, ascending: false
    )

    #expect(visible.count == 12)
    #expect(visible.contains { $0.id == SystemLayerActivity.stableID })
}

@MainActor
@Test func activeAppsSortsKnownMetricsBeforeGaps() {
    let known = ActiveAppRow.systemLayer(SystemLayerActivity(
        id: "known",
        currentCPUPercent: 1,
        totalWriteBytes: 1,
        currentWriteBytesPerSecond: 1,
        peakWriteBytesPerSecond: 1,
        averageNetworkReceiveBytesPerSecond: 1,
        averageNetworkSendBytesPerSecond: 1
    ))
    let gap = ActiveAppRow.systemLayer(SystemLayerActivity(
        id: "gap",
        currentCPUPercent: nil,
        totalWriteBytes: nil,
        currentWriteBytesPerSecond: nil,
        peakWriteBytesPerSecond: nil,
        averageNetworkReceiveBytesPerSecond: nil,
        averageNetworkSendBytesPerSecond: nil
    ))

    let visible = ProcessTable.visibleRows(
        [gap, known], limit: nil, sortKey: .writeCurrent, ascending: true
    )

    #expect(visible.map(\.id) == ["known", "gap"])
}

@MainActor
@Test func activeAppsHoverFreezesProcessesAndSystemLayerTogether() {
    let coordinator = ProcessHoverCoordinator()
    let initial = SystemLayerActivity(
        currentCPUPercent: 10,
        totalWriteBytes: 20,
        currentWriteBytesPerSecond: 30,
        peakWriteBytesPerSecond: 40,
        averageNetworkReceiveBytesPerSecond: 50,
        averageNetworkSendBytesPerSecond: 60
    )
    let updated = SystemLayerActivity(
        currentCPUPercent: 100,
        totalWriteBytes: 200,
        currentWriteBytesPerSecond: 300,
        peakWriteBytesPerSecond: 400,
        averageNetworkReceiveBytesPerSecond: 500,
        averageNetworkSendBytesPerSecond: 600
    )

    coordinator.tableHoverChanged(true, processes: [], systemLayerActivity: initial)
    coordinator.tableHoverChanged(true, processes: [], systemLayerActivity: updated)

    #expect(coordinator.frozenSystemLayerActivity?.currentWriteBytesPerSecond == 30)

    coordinator.tableHoverChanged(false, processes: [], systemLayerActivity: updated)

    #expect(coordinator.frozenProcesses == nil)
    #expect(coordinator.frozenSystemLayerActivity == nil)
}
