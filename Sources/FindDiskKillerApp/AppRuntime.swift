import FindDiskKillerCore
import Foundation
import Observation

@MainActor
@Observable
final class AppRuntime {
    static let shared = AppRuntime()

    let store: MonitorStore
    let history: HistoryModel
    let processDetailWindows: ProcessDetailWindowCoordinator
    private(set) var isStarted = false

    @ObservationIgnored private let flushHistoryAction: @MainActor () async -> Void
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var isSleeping = false
    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private var shouldResumeAfterWake = false

    init(
        store: MonitorStore = MonitorStore(),
        history: HistoryModel = HistoryModel(),
        processDetailWindows: ProcessDetailWindowCoordinator = ProcessDetailWindowCoordinator(),
        flushHistory: (@MainActor () async -> Void)? = nil
    ) {
        self.store = store
        self.history = history
        self.processDetailWindows = processDetailWindows
        flushHistoryAction = flushHistory ?? {
            await store.flushHistory()
            await history.refreshStorage()
        }
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
        await flushHistoryAction()
    }

    func resumeAfterWake() {
        guard isSleeping else { return }
        isSleeping = false
        store.resetCounterBaselines()
        if shouldResumeAfterWake, isStarted {
            store.start()
        }
        shouldResumeAfterWake = false
    }

    @discardableResult
    func prepareForTermination(timeout: Duration = .seconds(2)) async -> Bool {
        isTerminating = true
        startTask?.cancel()
        store.stop()
        let completion = FirstLifecycleCompletion()
        let flushHistoryAction = self.flushHistoryAction
        let flushTask = Task { @MainActor in
            await flushHistoryAction()
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
            flushTask.cancel()
        }
        return completed
    }

    private func startNow() async {
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
