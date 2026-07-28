import AppKit
import FindDiskKillerCore
import FindDiskKillerTraceProtocol
import SwiftUI

enum MainWindowMetrics {
    static let minimumWidth: CGFloat = 920
    static let minimumHeight: CGFloat = 620
    static let sidebarIdealWidth: CGFloat = 210
    static let providerOverviewContentWidth: CGFloat = 1_080
    static let defaultWidth: CGFloat = sidebarIdealWidth + providerOverviewContentWidth + 50
    static let defaultHeight: CGFloat = 760
}

private struct AgentStorageRefreshActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct AgentStorageBackActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var agentStorageRefreshAction: (() -> Void)? {
        get { self[AgentStorageRefreshActionKey.self] }
        set { self[AgentStorageRefreshActionKey.self] = newValue }
    }

    var agentStorageBackAction: (() -> Void)? {
        get { self[AgentStorageBackActionKey.self] }
        set { self[AgentStorageBackActionKey.self] = newValue }
    }
}

private struct MonitoringCommands: Commands {
    let store: MonitorStore
    @FocusedValue(\.agentStorageRefreshAction) private var refreshAgentStorage
    @FocusedValue(\.agentStorageBackAction) private var leaveAgentStorageProvider

    var body: some Commands {
        CommandMenu(L10n.text("监控")) {
            Button(L10n.text(store.isCollecting ? "停止采集" : "开始采集")) {
                store.isCollecting ? store.stop() : store.start()
            }
            .keyboardShortcut(".", modifiers: [.command])
            Divider()
            Button(L10n.text("刷新 AI 空间")) {
                refreshAgentStorage?()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(refreshAgentStorage == nil)
        }
        CommandGroup(after: .sidebar) {
            Button(L10n.text("返回 AI 空间")) {
                leaveAgentStorageProvider?()
            }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(leaveAgentStorageProvider == nil)
        }
    }
}

@main
struct FindDiskKillerApp: App {
    @NSApplicationDelegateAdaptor(FindDiskKillerApplicationDelegate.self) private var appDelegate
    @State private var runtime = AppRuntime.shared
    @AppStorage("showRateInMenuBar") private var showRateInMenuBar = true
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue

    var body: some Scene {
        Window("FindDiskKiller", id: "main") {
            RootView(
                store: runtime.store,
                processDetailWindows: runtime.processDetailWindows,
                history: runtime.history,
                agentStorage: runtime.agentStorage,
                navigation: runtime.navigation,
                updates: runtime.updates
            )
                .frame(
                    minWidth: MainWindowMetrics.minimumWidth,
                    minHeight: MainWindowMetrics.minimumHeight
                )
                .environment(\.locale, Locale(identifier: selectedLanguage.localeIdentifier))
                .id(appLanguage)
        }
        .defaultSize(width: MainWindowMetrics.defaultWidth, height: MainWindowMetrics.defaultHeight)
        .commands {
            SidebarCommands()
            FindDiskKillerCommands(runtime: runtime)
            MonitoringCommands(store: runtime.store)
        }

        WindowGroup(
            L10n.text("进程详情"),
            id: "process-detail",
            for: ProcessActivity.ID.self
        ) { $processID in
            if let processID,
               let presentation = runtime.processDetailWindows.presentation(for: processID) {
                ProcessDetailWindowRoot(
                    store: runtime.store,
                    coordinator: runtime.processDetailWindows,
                    presentation: presentation,
                    traceActivityRegistry: runtime.traceActivityRegistry
                )
                .environment(\.locale, Locale(identifier: selectedLanguage.localeIdentifier))
                .id(appLanguage)
            } else {
                ContentUnavailableView(
                    L10n.text("进程详情不可用"),
                    systemImage: "waveform.path.ecg"
                )
            }
        }
        .defaultSize(width: 980, height: 720)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarPanel(store: runtime.store)
                .frame(width: 340)
                .environment(\.locale, Locale(identifier: selectedLanguage.localeIdentifier))
                .id(appLanguage)
        } label: {
            if showRateInMenuBar {
                Label(
                    runtime.store.isDiskAvailable
                        ? ByteRateFormatter.rate(runtime.store.currentWriteRate)
                        : "--",
                    systemImage: menuBarSymbol
                )
            } else {
                Image(systemName: menuBarSymbol)
                    .accessibilityLabel("FindDiskKiller")
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguage) ?? .system
    }

    private var menuBarSymbol: String {
        switch runtime.store.health {
        case .elevated: "exclamationmark.triangle.fill"
        case .unavailable: "xmark.octagon.fill"
        case .stopped: "pause.circle"
        default: "internaldrive"
        }
    }
}

private struct FindDiskKillerCommands: Commands {
    let runtime: AppRuntime
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L10n.text("关于 FindDiskKiller")) {
                runtime.navigation.showAbout()
                presentMainWindow()
            }
        }

        CommandGroup(after: .appInfo) {
            Button(L10n.text("检查更新…")) {
                runtime.updates.checkForUpdates()
            }
            .disabled(!runtime.updates.canCheckForUpdates)
            Divider()
        }

        CommandGroup(replacing: .appSettings) {
            Button(L10n.text("设置…")) {
                runtime.navigation.showSettings(preserveCurrentPane: true)
                presentMainWindow()
            }
            .keyboardShortcut(",", modifiers: [.command])
        }
    }

    private func presentMainWindow() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        DispatchQueue.main.async {
            let window = NSApp.windows.first {
                $0.identifier?.rawValue == "main" || $0.title == "FindDiskKiller"
            }
            window?.deminiaturize(nil)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@MainActor
final class FindDiskKillerApplicationDelegate: NSObject, NSApplicationDelegate {
    private let runtime: AppRuntime
    private let reopenMainWindow: @MainActor (NSApplication) -> Bool
    private var observesWorkspaceLifecycle = false
    private var isWaitingForTerminationFlush = false

    override convenience init() {
        self.init(runtime: .shared)
    }

    init(
        runtime: AppRuntime,
        reopenMainWindow: (@MainActor (NSApplication) -> Bool)? = nil
    ) {
        self.runtime = runtime
        self.reopenMainWindow = reopenMainWindow ?? Self.restoreMainWindow
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--unregister-trace-helper") {
            NSApp.setActivationPolicy(.prohibited)
            Task { @MainActor in
                let controller = TraceHelperController()
                controller.unregister()
                print("trace-helper-unregister=\(controller.state)")
                NSApp.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--repair-trace-helper") {
            NSApp.setActivationPolicy(.prohibited)
            Task { @MainActor in
                let controller = TraceHelperController()
                do {
                    try await controller.repairService()
                    print("trace-helper-repair=\(controller.state)")
                } catch {
                    print("trace-helper-repair-failure=\(error)")
                }
                NSApp.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--authorize-and-test-trace-helper") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            Task { @MainActor in
                if await authorizeAndTestTraceHelperOnce() {
                    NSApp.terminate(nil)
                } else {
                    exit(EXIT_FAILURE)
                }
            }
            return
        }
        runtime.launch()
        observeWorkspaceLifecycle()
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey]
            as? Bool ?? true
        let shouldShowWindow = UserDefaults.standard.bool(forKey: "openMainWindowAtLogin")
        if !isDefaultLaunch && !shouldShowWindow {
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                NSApp.windows.forEach { $0.orderOut(nil) }
            }
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        sender.setActivationPolicy(.regular)
        sender.activate(ignoringOtherApps: true)
        return reopenMainWindow(sender)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isWaitingForTerminationFlush else { return .terminateLater }
        isWaitingForTerminationFlush = true
        Task { @MainActor [runtime] in
            _ = await runtime.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func observeWorkspaceLifecycle() {
        guard !observesWorkspaceLifecycle else { return }
        observesWorkspaceLifecycle = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(workspaceWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func workspaceWillSleep(_ notification: Notification) {
        Task { @MainActor [runtime] in
            await runtime.prepareForSleep()
        }
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        runtime.resumeAfterWake()
        runtime.reconcileTraceActivitySoon()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        runtime.reconcileTraceActivitySoon()
    }

    private static func restoreMainWindow(in application: NSApplication) -> Bool {
        guard let mainWindow = application.windows.first(where: {
            $0.identifier?.rawValue == "main" || $0.title == "FindDiskKiller"
        }) else {
            return false
        }
        mainWindow.makeKeyAndOrderFront(nil)
        return true
    }

    @MainActor
    private func authorizeAndTestTraceHelperOnce() async -> Bool {
        let controller = TraceHelperController()
        do {
            do {
                try await controller.prepareForTracing(recoveryMode: .automatic) { phase in
                    if phase == .repairing {
                        print("trace-helper-recovery=repairing")
                    }
                }
            } catch TraceHelperClientError.approvalRequired {
                print("trace-helper-authorization=waiting")
                controller.openLoginItemsSettings()
                try await controller.waitUntilAuthorizedAndReady()
            }
            let result = try await runTraceHelperSmokeTest(controller: controller)
            print(
                "trace-helper-smoke=success records=\(result.records) "
                    + "attributed=\(result.attributed) parsed-io=\(result.parsedIO)"
            )
            return true
        } catch {
            print("trace-helper-smoke=failure error=\(error)")
            return false
        }
    }

    @MainActor
    private func runTraceHelperSmokeTest(
        controller: TraceHelperController
    ) async throws -> (records: Int, attributed: Int, parsedIO: Int) {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        let sessionID = try await controller.startTrace(
            maximumDurationSeconds: 15,
            processIdentifiers: [pid]
        )
        let testURL = FileManager.default.temporaryDirectory
            .appending(path: "find-disk-killer-trace-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: testURL) }

        do {
            try await Task.sleep(for: .milliseconds(350))
            _ = FileManager.default.createFile(atPath: testURL.path, contents: nil)
            let handle = try FileHandle(forUpdating: testURL)
            for _ in 0..<8 {
                try handle.write(contentsOf: Data(repeating: 0x46, count: 16 * 1_024))
                try handle.synchronize()
                try handle.seek(toOffset: 0)
                _ = try handle.read(upToCount: 16 * 1_024)
                _ = try handle.seekToEnd()
            }
            try handle.close()

            var recordCount = 0
            var attributedCount = 0
            var parsedIOCount = 0
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline, parsedIOCount == 0 {
                let drain = try await controller.drainTrace(
                    sessionID: sessionID,
                    maximumRecordCount: TraceHelperProtocolConfiguration.maximumDrainRecordCount
                )
                recordCount += drain.records.count
                for record in drain.records {
                    if record.process?.pid == pid {
                        attributedCount += 1
                    }
                    if case .event = FileAccessTraceParser.parse(line: record.line, on: Date()) {
                        parsedIOCount += 1
                    }
                }
                if parsedIOCount == 0 {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            try await controller.stopTrace(sessionID: sessionID)
            guard recordCount > 0, attributedCount > 0, parsedIOCount > 0 else {
                throw TraceHelperClientError.invalidPayload
            }
            return (recordCount, attributedCount, parsedIOCount)
        } catch {
            try? await controller.stopTrace(sessionID: sessionID)
            throw error
        }
    }
}
