import Testing
@testable import FindDiskKillerApp

@Test func historyAnalysisUsesItsDedicatedNavigationPlaceholder() {
    #expect(AppSection.reports.navigationPlaceholderKind == .history)
}

@Test func agentStorageNeverUsesANavigationSkeleton() {
    #expect(AppSection.agentStorage.navigationPlaceholderKind == nil)
    #expect(AppSection.agentStorage.title == L10n.text("空间地图"))
    #expect(AppSection.agentStorage.symbol == "square.grid.3x3.square")
}

@Test func deferredSectionsKeepTheirPurposeBuiltNavigationPlaceholders() {
    #expect(AppSection.processes.navigationPlaceholderKind == .processes)
    #expect(AppSection.overview.navigationPlaceholderKind == .overview)
    #expect(AppSection.disks.navigationPlaceholderKind == .resources)
}

@Test func overviewSkeletonUsesTheLoadedOverviewLayoutContract() {
    #expect(OverviewLayoutContract.metricColumnCount == 3)
    #expect(OverviewLayoutContract.metricTileCount == 6)
    #expect(OverviewLayoutContract.applicationRowLimit == 12)
    #expect(OverviewLayoutContract.contentSpacing == 12)
    #expect(OverviewLayoutContract.metricSpacing == 10)
    #expect(OverviewLayoutContract.resourceControlWidth == 320)
}

@Test func appsSkeletonUsesTheLoadedProcessTableLayoutContract() {
    #expect(ProcessTableLayoutContract.loadingRowCount == 6)
    #expect(ProcessTableLayoutContract.headerHeight == 34)
    #expect(ProcessTableLayoutContract.rowHeight == 56)
}

@Test func secondaryPagesUseTheNowHeaderLayoutContract() {
    #expect(InstrumentPageHeaderLayout.minimumHeight == 62)
    #expect(InstrumentPageHeaderLayout.horizontalPadding == InstrumentDesign.Spacing.page)
    #expect(InstrumentPageHeaderLayout.topPadding == OverviewLayoutContract.pageTopPadding)
    #expect(InstrumentPageHeaderLayout.wideSpacing == 18)
}

@Test func agentStorageOwnsItsOnlyToolbarActivityControl() {
    #expect(!AppSection.agentStorage.showsMonitoringToolbar)
    #expect(AppSection.overview.showsMonitoringToolbar)
    #expect(AppSection.processes.showsMonitoringToolbar)
    #expect(AppSection.disks.showsMonitoringToolbar)
    #expect(AppSection.reports.showsMonitoringToolbar)
}

@Test func defaultWindowWidthSupportsTheTwoProviderOverview() {
    #expect(
        MainWindowMetrics.defaultWidth
            >= MainWindowMetrics.sidebarIdealWidth + MainWindowMetrics.providerOverviewContentWidth
    )
    #expect(MainWindowMetrics.defaultWidth > MainWindowMetrics.minimumWidth)
}

@Test func actionButtonsKeepAReadableVerticalRhythmAtEverySize() {
    #expect(AppActionButtonSize.compact.minimumHeight == 30)
    #expect(AppActionButtonSize.regular.minimumHeight == 34)
    #expect(AppActionButtonSize.large.minimumHeight == 38)
}
