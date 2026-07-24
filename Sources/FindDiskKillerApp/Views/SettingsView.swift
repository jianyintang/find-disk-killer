import FindDiskKillerCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let store: MonitorStore
    @AppStorage("showRateInMenuBar") private var showRateInMenuBar = true
    @AppStorage("sampleInterval") private var sampleInterval = 1.0
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue
    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var loginItemError: String?
    @State private var traceHelperState: TraceHelperServiceState = .notRegistered
    @State private var historyWasCleared = false

    var body: some View {
        TabView {
            Form {
                Section {
                    LabeledContent(L10n.text("语言")) {
                        Picker(L10n.text("语言"), selection: $appLanguage) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(language.localizedName).tag(language.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }

                    Toggle(
                        L10n.text("登录时启动"),
                        isOn: Binding(
                            get: { loginItemIsRegistered },
                            set: { shouldEnable in updateLoginItem(shouldEnable) }
                        )
                    )

                    if loginItemStatus == .requiresApproval {
                        SettingsInlineStatus(
                            text: L10n.text("登录项正在等待你在系统设置中批准。"),
                            systemImage: "person.badge.clock",
                            color: .orange,
                            actionTitle: L10n.text("打开登录项设置"),
                            action: {
                                SMAppService.openSystemSettingsLoginItems()
                            }
                        )
                    } else if let loginItemError {
                        SettingsInlineStatus(
                            text: L10n.format("无法更改登录项：%@", loginItemError),
                            systemImage: "exclamationmark.triangle",
                            color: .orange
                        )
                    }
                }

                Section {
                    Toggle(L10n.text("在菜单栏显示写入速率"), isOn: $showRateInMenuBar)
                    LabeledContent(L10n.text("采样间隔")) {
                        Picker(L10n.text("采样间隔"), selection: $sampleInterval) {
                            Text(L10n.text("1 秒")).tag(1.0)
                            Text(L10n.text("2 秒")).tag(2.0)
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label(L10n.text("通用"), systemImage: "gear") }

            Form {
                Section(L10n.text("监控数据")) {
                    Text(L10n.text("监控数据只保留在本机内存中，退出应用后会自动清除。"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(role: .destructive) {
                        store.clearHistory()
                        historyWasCleared = true
                    } label: {
                        Label(L10n.text("立即清除本次监控数据"), systemImage: "trash")
                    }

                    if historyWasCleared {
                        Label(L10n.text("本次监控数据已清除"), systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                    }
                }

                Section(L10n.text("深度追踪组件")) {
                    LabeledContent(L10n.text("状态"), value: traceHelperStatusText)

                    Text(L10n.text("只有你主动追踪文件或目录时，才会启用需要管理员批准的后台组件。"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if traceHelperCanBeRemoved {
                        Button(role: .destructive, action: removeTraceHelper) {
                            Label(L10n.text("停用并移除追踪组件"), systemImage: "xmark.shield")
                        }
                    }

                    if case .operationFailed(let message) = traceHelperState {
                        SettingsInlineStatus(
                            text: L10n.format("无法移除追踪组件：%@", message),
                            systemImage: "exclamationmark.triangle",
                            color: .orange
                        )
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label(L10n.text("数据与隐私"), systemImage: "hand.raised") }

            Form {
                Section {
                    LabeledContent("FindDiskKiller", value: versionDescription)
                    Text(L10n.text("在本机发现持续写盘、异常负载和磁盘健康信号。"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    Link(destination: releasesURL) {
                        Label(L10n.text("检查更新"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    Link(destination: privacyPolicyURL) {
                        Label(L10n.text("隐私政策"), systemImage: "hand.raised")
                    }
                    Link(destination: supportURL) {
                        Label(L10n.text("获取支持"), systemImage: "questionmark.circle")
                    }
                    Link(destination: sourceURL) {
                        Label(L10n.text("项目主页"), systemImage: "safari")
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label(L10n.text("关于"), systemImage: "info.circle") }
        }
        .scenePadding()
        .frame(width: 560, height: 430)
        .task {
            store.samplingInterval = sampleInterval
            refreshServiceStates()
        }
        .task(id: historyWasCleared) {
            guard historyWasCleared else { return }
            try? await Task.sleep(for: .seconds(3))
            historyWasCleared = false
        }
        .onChange(of: sampleInterval) { _, newValue in
            store.samplingInterval = newValue
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshServiceStates()
        }
    }

    private var loginItemIsRegistered: Bool {
        loginItemStatus == .enabled || loginItemStatus == .requiresApproval
    }

    private func updateLoginItem(_ shouldEnable: Bool) {
        loginItemError = nil
        do {
            if shouldEnable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemError = error.localizedDescription
        }
        loginItemStatus = SMAppService.mainApp.status
    }

    private var traceHelperCanBeRemoved: Bool {
        switch traceHelperState {
        case .notRegistered, .notFound:
            false
        default:
            true
        }
    }

    private var traceHelperStatusText: String {
        switch traceHelperState {
        case .notRegistered: L10n.text("未启用")
        case .requiresApproval: L10n.text("等待系统批准")
        case .enabled, .connecting, .ready: L10n.text("已启用")
        case .notFound: L10n.text("当前版本未包含")
        case .protocolMismatch: L10n.text("需要重新安装")
        case .connectionUnavailable: L10n.text("暂时无法连接")
        case .operationFailed: L10n.text("操作失败")
        }
    }

    private func refreshServiceStates() {
        loginItemStatus = SMAppService.mainApp.status
        let controller = TraceHelperController()
        controller.refreshStatus()
        traceHelperState = controller.state
    }

    private func removeTraceHelper() {
        let controller = TraceHelperController()
        _ = controller.unregister()
        traceHelperState = controller.state
    }

    private var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "-"
        return L10n.format("版本 %@（%@）", version, build)
    }

    private let privacyPolicyURL = URL(
        string: "https://github.com/jianyintang/find-disk-killer/blob/main/PRIVACY.md"
    )!
    private let supportURL = URL(
        string: "https://github.com/jianyintang/find-disk-killer/issues"
    )!
    private let sourceURL = URL(
        string: "https://github.com/jianyintang/find-disk-killer"
    )!
    private let releasesURL = URL(
        string: "https://github.com/jianyintang/find-disk-killer/releases/latest"
    )!
}

private struct SettingsInlineStatus: View {
    let text: String
    let systemImage: String
    let color: Color
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        text: String,
        systemImage: String,
        color: Color,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.text = text
        self.systemImage = systemImage
        self.color = color
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
    }
}
