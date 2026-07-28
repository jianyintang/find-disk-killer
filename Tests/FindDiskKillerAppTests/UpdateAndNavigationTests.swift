import Foundation
import FindDiskKillerTraceProtocol
import Testing
@testable import FindDiskKillerApp

@Test @MainActor
func sidebarNavigationPreservesMonitoringAndRoutesSettingsPanes() {
    let navigation = AppNavigationCoordinator()

    navigation.select(.monitoring(.processes))
    navigation.showSettings(.softwareUpdate)
    #expect(navigation.destination == .settings)
    #expect(navigation.settingsPane == .softwareUpdate)
    #expect(navigation.lastMonitoringDestination == .processes)

    navigation.showAbout()
    navigation.showSettings()
    #expect(navigation.settingsPane == .general)
}

@Test @MainActor
func settingsShortcutPreservesAnAlreadySelectedPane() {
    let navigation = AppNavigationCoordinator()
    navigation.showSettings(.dataAndPrivacy)
    navigation.showSettings(preserveCurrentPane: true)

    #expect(navigation.destination == .settings)
    #expect(navigation.settingsPane == .dataAndPrivacy)
}

@Test
func brandLinksUseLocalizedWebsiteAndFixedRepository() {
    #expect(BrandLinks.current(language: .simplifiedChinese).website.absoluteString
        == "https://finddiskkiller.com/zh-cn/")
    #expect(BrandLinks.current(language: .brazilianPortuguese).website.absoluteString
        == "https://finddiskkiller.com/pt-br/")
    #expect(BrandLinks.current(language: .japanese).website.absoluteString
        == "https://finddiskkiller.com/ja/")
    #expect(BrandLinks.current(language: .russian).github.absoluteString
        == "https://github.com/jianyintang/find-disk-killer")
}

@Test @MainActor
func traceAndUpdateReservationsAreMutuallyExclusive() throws {
    let registry = TraceActivityRegistry()
    let traceLease = try #require(registry.acquireTrace())

    #expect(registry.reserveUpdate() == nil)
    registry.markTraceStopping(traceLease)
    #expect(registry.status == .traceStopping)
    #expect(registry.reserveUpdate() == nil)
    registry.markTraceStopUnconfirmed(traceLease)
    #expect(registry.status == .stopUnconfirmed)
    #expect(registry.acquireTrace() == nil)

    registry.releaseTrace(traceLease)
    let updateLease = try #require(registry.reserveUpdate())
    #expect(registry.acquireTrace() == nil)
    registry.releaseUpdate(updateLease)
    #expect(registry.status == .idle)
}

@Test @MainActor
func orphanedHelperStateRequiresReconciliation() {
    let registry = TraceActivityRegistry()
    registry.markHelperBusyWithoutLocalLease()

    #expect(registry.needsHelperReconciliation)
    #expect(registry.acquireTrace() == nil)
    #expect(registry.reserveUpdate() == nil)

    registry.markHelperReadyWithoutLocalLease()
    #expect(!registry.needsHelperReconciliation)
    #expect(registry.canStartTrace)
    #expect(registry.canStartUpdate)
}

@Test
func traceHelperProtocolUsesBusyAwareVersionFive() {
    #expect(TraceHelperProtocolConfiguration.version == 5)
}
