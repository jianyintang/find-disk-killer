import AppKit
import FindDiskKillerCore
import SwiftUI

@main
struct FindDiskKillerApp: App {
    @NSApplicationDelegateAdaptor(FindDiskKillerApplicationDelegate.self) private var appDelegate
    @State private var store = MonitorStore()
    @State private var processDetailWindows = ProcessDetailWindowCoordinator()
    @State private var traceHelper = TraceHelperController()
    @AppStorage("showRateInMenuBar") private var showRateInMenuBar = true
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue

    var body: some Scene {
        Window("FindDiskKiller", id: "main") {
            RootView(store: store, processDetailWindows: processDetailWindows)
                .frame(minWidth: 920, minHeight: 620)
                .environment(\.locale, Locale(identifier: selectedLanguage.localeIdentifier))
                .id(appLanguage)
                .task {
                    traceHelper.refreshStatus()
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
        NSApp.setActivationPolicy(.regular)
    }
}
