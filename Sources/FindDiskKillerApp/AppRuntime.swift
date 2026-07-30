import FindDiskKillerCore
import Foundation
import Observation

@MainActor
@Observable
final class AppRuntime {
    static let shared = AppRuntime()

    let store: MonitorStore
    let history: HistoryModel
    let agentStorage: AgentStorageModel
    let processDetailWindows: ProcessDetailWindowCoordinator
    let navigation: AppNavigationCoordinator
    let traceActivityRegistry: TraceActivityRegistry
    let updates: UpdateCoordinator
    private(set) var isStarted = false

    @ObservationIgnored private let flushHistoryAction: @MainActor () async -> Void
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var isSleeping = false
    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private var shouldResumeAfterWake = false
    @ObservationIgnored private var reconciliationTask: Task<Void, Never>?

    init(
        store: MonitorStore = MonitorStore(),
        history: HistoryModel = HistoryModel(),
        agentStorage: AgentStorageModel = AgentStorageModel(),
        processDetailWindows: ProcessDetailWindowCoordinator = ProcessDetailWindowCoordinator(),
        navigation: AppNavigationCoordinator = AppNavigationCoordinator(),
        traceActivityRegistry: TraceActivityRegistry = TraceActivityRegistry(),
        defaults: UserDefaults = .standard,
        flushHistory: (@MainActor () async -> Void)? = nil
    ) {
        self.store = store
        self.history = history
        self.agentStorage = agentStorage
        self.processDetailWindows = processDetailWindows
        self.navigation = navigation
        self.traceActivityRegistry = traceActivityRegistry
        updates = UpdateCoordinator(activityRegistry: traceActivityRegistry)
        flushHistoryAction = flushHistory ?? {
            await store.flushHistory()
            await history.refreshStorage()
        }
        let storedInterval = (defaults.object(forKey: "sampleInterval") as? NSNumber)?.doubleValue
            ?? MonitorStore.defaultSamplingInterval
        store.setSamplingInterval(storedInterval)
        defaults.set(store.samplingInterval, forKey: "sampleInterval")
    }

    func launch() {
        guard !isStarted, !isTerminating, startTask == nil else { return }
        startTask = Task { [weak self] in
            await self?.startNow()
        }
    }

    func start() async {
        launch()
        let task = startTask
        await task?.value
    }

    func prepareForSleep() async {
        guard !isSleeping else { return }
        isSleeping = true
        shouldResumeAfterWake = store.isCollecting || startTask != nil
        if store.isCollecting {
            store.stop()
        } else {
            store.resetCounterBaselines()
        }
        await agentStorage.prepareForSleep()
        await flushHistoryAction()
    }

    func resumeAfterWake() {
        guard isSleeping else { return }
        isSleeping = false
        store.resetCounterBaselines()
        if shouldResumeAfterWake, isStarted {
            store.start()
        }
        agentStorage.resumeAfterWake()
        shouldResumeAfterWake = false
    }

    @discardableResult
    func prepareForTermination(timeout: Duration = .seconds(2)) async -> Bool {
        isTerminating = true
        startTask?.cancel()
        store.stop()
        let completion = FirstLifecycleCompletion()
        let agentStorage = self.agentStorage
        let flushHistoryAction = self.flushHistoryAction
        let shutdownTask = Task { @MainActor in
            async let stopAgentStorage: Void = agentStorage.prepareForTermination()
            async let flushHistory: Void = flushHistoryAction()
            _ = await (stopAgentStorage, flushHistory)
            await completion.resolve(true)
        }
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await completion.resolve(false)
        }
        let completed = await completion.wait()
        if completed {
            timeoutTask.cancel()
        } else {
            shutdownTask.cancel()
        }
        return completed
    }

    private func startNow() async {
        // Appcast checks are read-only. Start Sparkle immediately, while the
        // installation gate remains closed until helper reconciliation finishes.
        traceActivityRegistry.markHelperBusyWithoutLocalLease()
        updates.start()
        await reconcileTraceActivity()
        if traceActivityRegistry.needsHelperReconciliation {
            scheduleInterlockReconciliation(immediate: false)
        }
        await history.start(with: store)
        guard !Task.isCancelled, !isTerminating else {
            startTask = nil
            return
        }
        isStarted = true
        startTask = nil
        if isSleeping {
            shouldResumeAfterWake = true
        } else {
            store.start()
        }
    }

    private func reconcileTraceActivity() async {
        let helper = TraceHelperController()
        helper.refreshStatus()
        switch helper.state {
        case .notRegistered, .requiresApproval, .notFound, .installationRequired:
            traceActivityRegistry.markHelperReadyWithoutLocalLease()
        case .repairing, .repairAvailable, .connectionUnavailable, .operationFailed:
            traceActivityRegistry.markHelperBusyWithoutLocalLease()
        case .protocolMismatch:
            await repairOutdatedHelperForInterlock(helper)
        case .enabled, .connecting, .ready:
            do {
                let status = try await helper.activityStatus()
                if status == .ready {
                    traceActivityRegistry.markHelperReadyWithoutLocalLease()
                } else {
                    traceActivityRegistry.markHelperBusyWithoutLocalLease()
                }
            } catch TraceHelperClientError.protocolMismatch {
                await repairOutdatedHelperForInterlock(helper)
            } catch {
                traceActivityRegistry.markHelperBusyWithoutLocalLease()
            }
        }
    }

    func reconcileTraceActivitySoon() {
        scheduleInterlockReconciliation(immediate: true)
    }

    private func scheduleInterlockReconciliation(immediate: Bool) {
        reconciliationTask?.cancel()
        reconciliationTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .seconds(3))
            }
            while !Task.isCancelled {
                guard let self else { return }
                await self.reconcileTraceActivity()
                if !self.traceActivityRegistry.needsHelperReconciliation {
                    self.reconciliationTask = nil
                    return
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func repairOutdatedHelperForInterlock(_ helper: TraceHelperController) async {
        do {
            // Replacing an already-registered old helper also terminates any legacy
            // child process, restoring a trustworthy idle/busy signal for updates.
            try await helper.repairService()
            let status = try await helper.activityStatus()
            if status == .ready {
                traceActivityRegistry.markHelperReadyWithoutLocalLease()
            } else {
                traceActivityRegistry.markHelperBusyWithoutLocalLease()
            }
        } catch {
            traceActivityRegistry.markHelperBusyWithoutLocalLease()
        }
    }
}

private actor FirstLifecycleCompletion {
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ result: Bool) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }
}
