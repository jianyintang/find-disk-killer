import Testing
@testable import FindDiskKillerApp

@Test func historyAnalysisUsesItsDedicatedNavigationPlaceholder() {
    #expect(AppSection.reports.navigationPlaceholderKind == .history)
}

@Test func otherSectionsKeepTheirPurposeBuiltNavigationPlaceholders() {
    #expect(AppSection.processes.navigationPlaceholderKind == .processes)
    #expect(AppSection.agentStorage.navigationPlaceholderKind == .agentStorage)
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
