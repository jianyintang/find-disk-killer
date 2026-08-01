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
