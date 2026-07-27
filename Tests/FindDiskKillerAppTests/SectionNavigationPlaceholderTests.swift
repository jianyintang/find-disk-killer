import Testing
@testable import FindDiskKillerApp

@Test func historyAnalysisUsesItsDedicatedNavigationPlaceholder() {
    #expect(AppSection.reports.navigationPlaceholderKind == .history)
}

@Test func otherSectionsKeepTheirPurposeBuiltNavigationPlaceholders() {
    #expect(AppSection.processes.navigationPlaceholderKind == .processes)
    #expect(AppSection.overview.navigationPlaceholderKind == .overview)
    #expect(AppSection.disks.navigationPlaceholderKind == .resources)
}
