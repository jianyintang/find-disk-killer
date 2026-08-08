import Foundation
import Testing
import FindDiskKillerCore
@testable import FindDiskKillerApp

private func warningSample(_ offset: TimeInterval, _ value: Double?, segment: Int = 0) -> WarningThroughputSample {
    WarningThroughputSample(
        timestamp: Date(timeIntervalSinceReferenceDate: offset),
        value: value,
        segment: segment
    )
}

@Test func warningOverlayConnectsThresholdCrossings() {
    let segments = warningThroughputSegments(
        samples: [
            warningSample(0, 10),
            warningSample(1, 30),
            warningSample(2, 40),
            warningSample(3, 10)
        ],
        threshold: 20
    )

    #expect(segments.count == 1)
    #expect(segments[0].points.map(\.value) == [20, 30, 40, 20])
    #expect(segments[0].points.map(\.timestamp) == [
        Date(timeIntervalSinceReferenceDate: 0.5),
        Date(timeIntervalSinceReferenceDate: 1),
        Date(timeIntervalSinceReferenceDate: 2),
        Date(timeIntervalSinceReferenceDate: 2.6666666666666665)
    ])
}

@Test func warningOverlayDoesNotBridgeSamplingGapsOrSegments() {
    let segments = warningThroughputSegments(
        samples: [
            warningSample(0, 10),
            warningSample(1, 30),
            warningSample(2, nil),
            warningSample(3, 35, segment: 1),
            warningSample(4, 10, segment: 1)
        ],
        threshold: 20
    )

    #expect(segments.count == 2)
    #expect(segments[0].points.map(\.value) == [20, 30])
    #expect(segments[1].points.map(\.value) == [35, 20])
}

@Test func cpuCoreEnergyBarsUseTenSegmentsPerCore() {
    #expect(InstrumentDesign.Energy.cpuSegments == 10)
}

@Test func networkMetricBucketsSpanTheSelectedTimeWindow() {
    let end = Date(timeIntervalSinceReferenceDate: 1_000)
    let samples = [
        NetworkBarSample(timestamp: end.addingTimeInterval(-600), receive: 50, send: 5),
        NetworkBarSample(timestamp: end.addingTimeInterval(-30), receive: 3, send: 8)
    ]

    let oneMinute = networkBarBuckets(
        samples: samples,
        endingAt: end,
        windowDuration: SampleRange.minute.seconds,
        bucketCount: 6
    )
    let fifteenMinutes = networkBarBuckets(
        samples: samples,
        endingAt: end,
        windowDuration: SampleRange.fifteenMinutes.seconds,
        bucketCount: 6
    )

    #expect(oneMinute.count == 6)
    #expect(oneMinute.compactMap(\.receive).max() == 3)
    #expect(fifteenMinutes.compactMap(\.receive).max() == 50)
    #expect(fifteenMinutes.compactMap(\.send).max() == 8)
}

@Test func overviewDiskLayoutFitsOneInternalVolumeWithoutAnEmptyGap() {
    let layout = OverviewDiskLayout(volumeCount: 1)

    #expect(layout.rowHeight == OverviewDiskLayout.singleVolumeRowHeight)
    #expect(layout.volumeViewportHeight == OverviewDiskLayout.singleVolumeRowHeight)
    #expect(abs(layout.contentHeight
        - OverviewDiskLayout.leadValueHeight
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
        - OverviewDiskLayout.leadValueHeight
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

@Test func processTableCompressesToTheViewportBeforeEnablingHorizontalScroll() {
    let base = ProcessColumnWidths.defaults
    let availableWidth = base.tableWidth - 100

    let resolved = base.adapted(to: availableWidth)

    #expect(abs(resolved.tableWidth - availableWidth) < 0.001)
    for column in ProcessColumn.allCases {
        #expect(resolved[column] >= column.limits.lowerBound)
    }
}

@Test func processTableUsesReadableMinimumWidthsBeforeHorizontalScrolling() {
    let base = ProcessColumnWidths.defaults
    let minimumWidth = ProcessColumn.allCases.reduce(ProcessColumnWidths.horizontalPadding) {
        $0 + $1.limits.lowerBound
    } + CGFloat(ProcessColumn.allCases.count) * ProcessColumn.resizeHandleWidth

    let resolved = base.adapted(to: minimumWidth - 80)

    #expect(abs(resolved.tableWidth - minimumWidth) < 0.001)
    #expect(resolved.tableWidth > minimumWidth - 80)
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
    #expect(ProcessTable.appsPageSize == 20)
}

@MainActor
@Test(arguments: [0, 1, 20, 21, 40, 41])
func activeAppsPaginationUsesTwentyRowsPerPage(rowCount: Int) {
    let rows = (0..<rowCount).map(paginationRow)
    let expectedPageCount = max(1, (rowCount + ProcessTable.appsPageSize - 1) / ProcessTable.appsPageSize)

    let firstPage = ProcessTable.page(
        rows,
        pageSize: ProcessTable.appsPageSize,
        requestedPage: 0
    )
    let lastPage = ProcessTable.page(
        rows,
        pageSize: ProcessTable.appsPageSize,
        requestedPage: expectedPageCount - 1
    )
    let expectedLastPageCount = rowCount == 0
        ? 0
        : rowCount - ((expectedPageCount - 1) * ProcessTable.appsPageSize)

    #expect(firstPage.totalPages == expectedPageCount)
    #expect(firstPage.rows.count == min(rowCount, ProcessTable.appsPageSize))
    #expect(lastPage.rows.count == expectedLastPageCount)
}

@MainActor
@Test func activeAppsPaginationClampsPageAfterResultsShrink() {
    let rows = (0..<21).map(paginationRow)

    let page = ProcessTable.page(
        Array(rows.prefix(20)),
        pageSize: ProcessTable.appsPageSize,
        requestedPage: 1
    )

    #expect(page.pageIndex == 0)
    #expect(page.totalPages == 1)
    #expect(page.rows.count == 20)
}

@MainActor
@Test func nowTopTwelveDoesNotEnablePagination() {
    let rows = (0..<20).map(paginationRow)
    let topTwelve = ProcessTable.visibleRows(
        rows,
        limit: 12,
        sortKey: .name,
        ascending: true
    )
    let page = ProcessTable.page(topTwelve, pageSize: nil, requestedPage: 4)

    #expect(page.rows.count == 12)
    #expect(page.pageIndex == 0)
    #expect(page.totalPages == 1)
}

private func paginationRow(_ index: Int) -> ActiveAppRow {
    .systemLayer(SystemLayerActivity(
        id: "row-\(index)",
        currentCPUPercent: nil,
        totalWriteBytes: nil,
        currentWriteBytesPerSecond: nil,
        peakWriteBytesPerSecond: nil,
        averageNetworkReceiveBytesPerSecond: nil,
        averageNetworkSendBytesPerSecond: nil
    ))
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

@MainActor
@Test func activeAppsScrollActivityDefersHoverUntilScrollingSettles() async {
    let coordinator = ProcessHoverCoordinator()

    coordinator.scrollingStarted()
    #expect(coordinator.isScrolling)

    coordinator.scrollingEnded()
    let deadline = ContinuousClock.now + .seconds(1)
    while coordinator.isScrolling, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(!coordinator.isScrolling)
}

@MainActor
@Test func activeAppsDefersSamplesButNotSearchChangesWhileScrolling() {
    let previous = ProcessTableRevision(sample: 1, query: "")

    #expect(!ProcessTable.shouldRefreshContent(
        oldRevision: previous,
        newRevision: ProcessTableRevision(sample: 2, query: ""),
        isScrolling: true
    ))
    #expect(ProcessTable.shouldRefreshContent(
        oldRevision: previous,
        newRevision: ProcessTableRevision(sample: 2, query: "codex"),
        isScrolling: true
    ))
    #expect(ProcessTable.shouldRefreshContent(
        oldRevision: previous,
        newRevision: ProcessTableRevision(sample: 2, query: ""),
        isScrolling: false
    ))
}

@MainActor
@Test func activeAppsPreformatsSystemLayerRowsBeforeRendering() {
    let activity = SystemLayerActivity(
        currentCPUPercent: 12.5,
        totalWriteBytes: 2_000,
        currentWriteBytesPerSecond: nil,
        peakWriteBytesPerSecond: 4_000,
        averageNetworkReceiveBytesPerSecond: nil,
        averageNetworkSendBytesPerSecond: 8_000
    )

    guard case let .systemLayer(presentation) = ProcessTable.presentation(
        for: .systemLayer(activity)
    ) else {
        Issue.record("Expected a preformatted system-layer row")
        return
    }

    #expect(presentation.cpu == PercentFormatter.cpu(12.5))
    #expect(presentation.totalWrite == ByteRateFormatter.bytes(2_000))
    #expect(presentation.currentWrite == nil)
    #expect(presentation.networkUpload == ByteRateFormatter.rate(8_000))
    #expect(presentation.accessibilityValue.contains(L10n.text("缺口")))
}
