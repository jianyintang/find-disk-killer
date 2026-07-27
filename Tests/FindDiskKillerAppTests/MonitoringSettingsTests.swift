import AppKit
import Foundation
import Testing
@testable import FindDiskKillerApp
@testable import FindDiskKillerCore

@MainActor
private final class FakeLoginItemService: LoginItemServicing {
    var status: LoginItemEffectiveStatus
    var registerError: Error?
    var unregisterError: Error?
    var openedSettings = false

    init(status: LoginItemEffectiveStatus) {
        self.status = status
    }

    func register() throws {
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        if let unregisterError { throw unregisterError }
        status = .disabled
    }

    func openSystemSettings() { openedSettings = true }
}

private struct LoginFixtureError: LocalizedError {
    var errorDescription: String? { "Registration failed" }
}

@MainActor
@Test func samplingIntervalDefaultsToThreeSecondsAndClampsToSupportedBounds() {
    let store = MonitorStore()

    #expect(store.samplingInterval == 3)
    store.setSamplingInterval(0)
    #expect(store.samplingInterval == 1)
    store.setSamplingInterval(90)
    #expect(store.samplingInterval == 60)
    store.setSamplingInterval(7.6)
    #expect(store.samplingInterval == 8)
}

@MainActor
@Test func runtimeLoadsThePersistedSamplingIntervalBeforeCollectionStarts() throws {
    let suiteName = "SamplingIntervalTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(12.0, forKey: "sampleInterval")
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MonitorStore()

    _ = AppRuntime(
        store: store,
        history: HistoryModel(databaseURL: root.appending(path: "monitor.sqlite3")),
        defaults: defaults
    )

    #expect(store.samplingInterval == 12)
}

@MainActor
@Test func loginItemModelTracksEffectiveSystemState() {
    let service = FakeLoginItemService(status: .requiresApproval)
    let model = LoginItemSettingsModel(service: service)
    #expect(model.desiredEnabled)
    #expect(model.effectiveStatus == .requiresApproval)

    model.setEnabled(false)
    #expect(!model.desiredEnabled)
    #expect(model.effectiveStatus == .disabled)
}

@MainActor
@Test func loginItemModelRollsBackDesiredStateAfterFailure() {
    let service = FakeLoginItemService(status: .disabled)
    service.registerError = LoginFixtureError()
    let model = LoginItemSettingsModel(service: service)

    model.setEnabled(true)

    #expect(!model.desiredEnabled)
    guard case .failed(let message) = model.effectiveStatus else {
        Issue.record("Expected a failed login item state")
        return
    }
    #expect(message == "Registration failed")
}

@MainActor
@Test func historyPreferencesSurviveModelRecreation() async throws {
    let suiteName = "HistoryModelTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appending(path: "monitor.sqlite3")

    let first = HistoryModel(defaults: defaults, databaseURL: databaseURL)
    await first.setEnabled(true)
    await first.setRetention(.oneYear)
    await first.setStorageBudget(.mb160)
    await first.setApplicationActivityEnabled(false)

    let recreated = HistoryModel(defaults: defaults, databaseURL: databaseURL)
    #expect(recreated.configuration == HistoryConfiguration(
        isEnabled: true,
        retention: .oneYear,
        storageBudget: .mb160,
        savesApplicationActivity: false
    ))
}

@MainActor
@Test func runtimeSleepsOnlyAfterFlushingAndResumesCollectionWithFreshBaselines() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    var flushCount = 0
    let store = MonitorStore(sampleProvider: {
        try? await Task.sleep(for: .seconds(60))
        return .runtimeFixture
    })
    let history = HistoryModel(databaseURL: root.appending(path: "monitor.sqlite3"))
    let runtime = AppRuntime(store: store, history: history) {
        await Task.yield()
        flushCount += 1
    }

    await runtime.start()
    await runtime.prepareForSleep()

    #expect(flushCount == 1)
    #expect(!store.isCollecting)

    runtime.resumeAfterWake()
    #expect(store.isCollecting)
    store.stop()
}

@MainActor
@Test func runtimeStartsCollectionWithoutConstructingTheMainWindow() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MonitorStore(sampleProvider: {
        try? await Task.sleep(for: .seconds(60))
        return .runtimeFixture
    })
    let runtime = AppRuntime(
        store: store,
        history: HistoryModel(databaseURL: root.appending(path: "monitor.sqlite3"))
    ) {}

    await runtime.start()
    runtime.launch()

    #expect(runtime.isStarted)
    #expect(store.isCollecting)
    store.stop()
}

@MainActor
@Test func terminationFlushReturnsWhenItsDeadlineExpires() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = AppRuntime(
        store: MonitorStore(),
        history: HistoryModel(databaseURL: root.appending(path: "monitor.sqlite3"))
    ) {
        try? await Task.sleep(for: .seconds(10))
    }
    let clock = ContinuousClock()
    let started = clock.now

    let completed = await runtime.prepareForTermination(timeout: .milliseconds(20))

    #expect(!completed)
    #expect(started.duration(to: clock.now) < .seconds(1))
}

@MainActor
@Test func applicationReopenRestoresTheMainWindowAndRegularActivationPolicy() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = AppRuntime(
        store: MonitorStore(),
        history: HistoryModel(databaseURL: root.appending(path: "monitor.sqlite3"))
    ) {}
    var restoredMainWindow = false
    let delegate = FindDiskKillerApplicationDelegate(runtime: runtime) { _ in
        restoredMainWindow = true
        return true
    }

    let application = NSApplication.shared
    let handled = delegate.applicationShouldHandleReopen(application, hasVisibleWindows: false)

    #expect(handled)
    #expect(restoredMainWindow)
    #expect(application.activationPolicy() == .regular)
}

private extension SystemSnapshot {
    static var runtimeFixture: Self {
        Self(
            date: Date(),
            uptime: 1,
            processes: [],
            disks: [],
            volumes: [],
            cpuUserTicks: 0,
            cpuSystemTicks: 0,
            cpuNiceTicks: 0,
            cpuIdleTicks: 0,
            networkInterfaces: [],
            cpuStatsAvailable: false,
            networkInterfacesAvailable: false,
            processNetworkAvailable: false
        )
    }
}
