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

@Test
func agentStorageCompatibilityLinkDoesNotIncludePrivateDiagnosticInput() throws {
    let privateInput = "/Users/alice/.codex/logs_2.sqlite thread-title task-id"
    let url = BrandLinks.agentStorageCompatibilityIssueURL(
        provider: .codex,
        component: privateInput
    )
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let values = components.queryItems?.compactMap(\.value).joined(separator: "\n") ?? ""

    #expect(!values.contains(privateInput))
    #expect(!values.contains("alice"))
    #expect(values.contains("unknown component"))
    #expect(url.host == "github.com")
}

@Test @MainActor
func traceAndUpdateInstallationReservationsAreMutuallyExclusive() throws {
    let registry = TraceActivityRegistry()
    let traceLease = try #require(registry.acquireTrace())

    #expect(registry.reserveUpdateInstallation() == nil)
    registry.markTraceStopping(traceLease)
    #expect(registry.status == .traceStopping)
    #expect(registry.reserveUpdateInstallation() == nil)
    registry.markTraceStopUnconfirmed(traceLease)
    #expect(registry.status == .stopUnconfirmed)
    #expect(registry.acquireTrace() == nil)

    registry.releaseTrace(traceLease)
    let updateLease = try #require(registry.reserveUpdateInstallation())
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
    #expect(registry.reserveUpdateInstallation() == nil)

    registry.markHelperReadyWithoutLocalLease()
    #expect(!registry.needsHelperReconciliation)
    #expect(registry.canStartTrace)
    #expect(registry.canBeginUpdateInstallation)
}

@Test @MainActor
func helperApprovalStateDoesNotPretendThatATraceIsStopping() {
    let registry = TraceActivityRegistry()

    registry.markHelperReadyWithoutLocalLease()

    #expect(registry.status == .idle)
    #expect(registry.canBeginUpdateInstallation)
}

@Test
func appcastChecksRemainAvailableAcrossTraceInterlockStates() {
    let statuses: [TraceUpdateInterlockStatus] = [
        .idle,
        .traceStartingOrRunning,
        .traceStopping,
        .stopUnconfirmed,
        .updatePendingOrRunning
    ]

    #expect(statuses.allSatisfy(UpdateInterlockPolicy.allowsAppcastCheck))
}

@Test @MainActor
func postponedInstallationContinuesOnceAndKeepsTracingBlocked() async throws {
    let registry = TraceActivityRegistry()
    let traceLease = try #require(registry.acquireTrace())
    let interlock = UpdateInstallationInterlock(activityRegistry: registry)
    var continuationCount = 0

    #expect(interlock.postponeIfNeeded { continuationCount += 1 })
    registry.releaseTrace(traceLease)

    for _ in 0..<20 where continuationCount == 0 {
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(continuationCount == 1)
    #expect(interlock.isActive)
    #expect(registry.acquireTrace() == nil)

    interlock.release()
    #expect(!interlock.isActive)
    #expect(registry.canStartTrace)
}

@Test @MainActor
func cancelingPostponedInstallationDoesNotInvokeItsHandler() async throws {
    let registry = TraceActivityRegistry()
    let traceLease = try #require(registry.acquireTrace())
    let interlock = UpdateInstallationInterlock(activityRegistry: registry)
    var continued = false

    #expect(interlock.postponeIfNeeded { continued = true })
    interlock.release()
    registry.releaseTrace(traceLease)
    try await Task.sleep(for: .milliseconds(300))

    #expect(!continued)
    #expect(!interlock.isActive)
    #expect(registry.canStartTrace)
}

@Test
func traceHelperProtocolUsesBusyAwareVersionFive() {
    #expect(TraceHelperProtocolConfiguration.version == 5)
}
