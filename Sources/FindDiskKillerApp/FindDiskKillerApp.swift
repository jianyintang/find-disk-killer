import AppKit
import FindDiskKillerCore
import FindDiskKillerTraceProtocol
import SwiftUI

@main
struct FindDiskKillerApp: App {
    @NSApplicationDelegateAdaptor(FindDiskKillerApplicationDelegate.self) private var appDelegate
    @State private var store = MonitorStore()
    @State private var processDetailWindows = ProcessDetailWindowCoordinator()
    @AppStorage("showRateInMenuBar") private var showRateInMenuBar = true
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue

    var body: some Scene {
        Window("FindDiskKiller", id: "main") {
            RootView(
                store: store,
                processDetailWindows: processDetailWindows
            )
                .frame(minWidth: 920, minHeight: 620)
                .environment(\.locale, Locale(identifier: selectedLanguage.localeIdentifier))
                .id(appLanguage)
                .task {
                    store.start()
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            SidebarCommands()
            CommandMenu(L10n.text("监控")) {
                Button(L10n.text(store.isCollecting ? "停止采集" : "开始采集")) {
                    store.isCollecting ? store.stop() : store.start()
                }
                .keyboardShortcut(".", modifiers: [.command])
            }
        }

        WindowGroup(
            L10n.text("进程详情"),
            id: "process-detail",
            for: ProcessActivity.ID.self
        ) { $processID in
            if let processID,
               let presentation = processDetailWindows.presentation(for: processID) {
                ProcessDetailWindowRoot(
                    store: store,
                    coordinator: processDetailWindows,
                    presentation: presentation
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
            MenuBarPanel(store: store)
                .frame(width: 340)
                .environment(\.locale, Locale(identifier: selectedLanguage.localeIdentifier))
                .id(appLanguage)
        } label: {
            if showRateInMenuBar {
                Label(
                    store.isDiskAvailable
                        ? ByteRateFormatter.rate(store.currentWriteRate)
                        : "--",
                    systemImage: menuBarSymbol
                )
            } else {
                Image(systemName: menuBarSymbol)
                    .accessibilityLabel("FindDiskKiller")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
                .environment(\.locale, Locale(identifier: selectedLanguage.localeIdentifier))
                .id(appLanguage)
        }
    }

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguage) ?? .system
    }

    private var menuBarSymbol: String {
        switch store.health {
        case .elevated: "exclamationmark.triangle.fill"
        case .unavailable: "xmark.octagon.fill"
        case .stopped: "pause.circle"
        default: "internaldrive"
        }
    }
}

final class FindDiskKillerApplicationDelegate: NSObject, NSApplicationDelegate {
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
                await authorizeAndTestTraceHelperOnce()
                NSApp.terminate(nil)
            }
            return
        }
        NSApp.setActivationPolicy(.regular)
    }

    @MainActor
    private func authorizeAndTestTraceHelperOnce() async {
        let controller = TraceHelperController()
        do {
            // The final build is registered exactly once. No retry in this
            // diagnostic path is allowed to mutate the authorization state.
            try await controller.repairService()
            if controller.state == .requiresApproval {
                print("trace-helper-authorization=waiting")
                controller.openLoginItemsSettings()
            }
            try await controller.waitUntilAuthorizedAndReady()
            let result = try await runTraceHelperSmokeTest(controller: controller)
            print(
                "trace-helper-smoke=success records=\(result.records) "
                    + "attributed=\(result.attributed) parsed-io=\(result.parsedIO)"
            )
        } catch {
            print("trace-helper-smoke=failure error=\(error)")
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
