import AppKit
import FindDiskKillerCore
import SwiftUI

private enum SettingsPickerStyle {
    case segmented
    case menu
}

struct SettingsPage: View {
    let store: MonitorStore
    let history: HistoryModel
    let navigation: AppNavigationCoordinator
    let updates: UpdateCoordinator
    let agentStorage: AgentStorageModel
    @AppStorage("showRateInMenuBar") private var showRateInMenuBar = true
    @AppStorage("sampleInterval") private var sampleInterval = MonitorStore.defaultSamplingInterval
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue
    @AppStorage("openMainWindowAtLogin") private var openMainWindowAtLogin = false
    @AppStorage(AgentStoragePreferences.hidePrivateDetailsKey)
    private var hidesAgentStoragePrivateDetails = false
    @State private var loginItem = LoginItemSettingsModel()
    @State private var nodeRuntime = ClaudeNodeRuntimeStatusModel()
    @State private var traceHelperState: TraceHelperServiceState = .notRegistered
    @State private var historyWasCleared = false
    @State private var confirmation: HistorySettingsConfirmation?
    @State private var showsDisableHistoryOptions = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                Text(L10n.text("设置"))
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                ViewThatFits(in: .horizontal) {
                    settingsPanePicker(style: .segmented)
                        .fixedSize(horizontal: true, vertical: false)
                    settingsPanePicker(style: .menu)
                        .frame(width: 190)
                }
            }
            .padding(.horizontal, 28)
            .frame(height: 64)

            Divider()

            Group {
                switch navigation.settingsPane {
                case .general:
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
                            get: { loginItem.desiredEnabled },
                            set: { loginItem.setEnabled($0) }
                        )
                    )
                    .disabled(loginItem.isTransitioning)

                    if loginItem.desiredEnabled {
                        Toggle(
                            L10n.text("登录后打开主窗口"),
                            isOn: $openMainWindowAtLogin
                        )
                    }

                    if loginItem.effectiveStatus == .requiresApproval {
                        SettingsInlineStatus(
                            text: L10n.text("登录项正在等待你在系统设置中批准。"),
                            systemImage: "person.badge.clock",
                            color: .orange,
                            actionTitle: L10n.text("打开登录项设置"),
                            action: loginItem.openSystemSettings
                        )
                    } else if case .failed(let message) = loginItem.effectiveStatus {
                        SettingsInlineStatus(
                            text: L10n.format("无法更改登录项：%@", message),
                            systemImage: "exclamationmark.triangle",
                            color: .orange
                        )
                    }
                }

                Section {
                    Toggle(L10n.text("在菜单栏显示写入速率"), isOn: $showRateInMenuBar)
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            Text(L10n.text("采样间隔"))
                            Spacer(minLength: 24)
                            HStack(spacing: 5) {
                                TextField(
                                    L10n.text("采样间隔"),
                                    value: samplingIntervalBinding,
                                    format: .number.precision(.fractionLength(0))
                                )
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 42)
                                Text(L10n.text("秒"))
                                    .fixedSize()
                            }
                        }

                        Slider(
                            value: samplingIntervalBinding,
                            in: MonitorStore.samplingIntervalRange,
                            step: 1
                        )
                        .labelsHidden()
                        .accessibilityLabel(L10n.text("采样间隔"))

                        HStack {
                            Text("1")
                            Spacer()
                            Text("60")
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }

                Section(L10n.text("Claude 官方清理")) {
                    LabeledContent(L10n.text("Node.js 运行时")) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(nodeRuntimeStatusColor)
                                .frame(width: 8, height: 8)
                                .accessibilityHidden(true)
                            Text(nodeRuntimeStatusText)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }

                    if case .available(let availability) = nodeRuntime.phase {
                        LabeledContent(L10n.text("运行时位置")) {
                            Text(agentStoragePath(availability.path))
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Text(L10n.text("批量清理 Claude Code 聊天时，需要 Node.js 运行 Anthropic 官方 SDK；会自动复用本机已安装的 Node.js 20 或更高版本。"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    switch nodeRuntime.phase {
                    case .missing, .failed:
                        HStack {
                            Button {
                                nodeRuntime.download()
                            } label: {
                                Label(
                                    L10n.format("下载 Node.js v%@", ClaudeNodeRuntime.pinnedVersion),
                                    systemImage: "arrow.down.circle"
                                )
                            }
                            Spacer()
                            Button(L10n.text("重新检测")) {
                                nodeRuntime.refresh()
                            }
                        }
                    case .downloading, .verifying, .installing:
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text(nodeRuntimeStatusText)
                                .foregroundStyle(.secondary)
                        }
                    case .checking, .available:
                        EmptyView()
                    }

                    if case .failed(let message) = nodeRuntime.phase {
                        SettingsInlineStatus(
                            text: message,
                            systemImage: "exclamationmark.triangle",
                            color: .orange
                        )
                    }
                }
            }
            .formStyle(.grouped)

                case .dataAndPrivacy:
            Form {
                Section(L10n.text("AI Agent 空间")) {
                    Toggle(
                        L10n.text("隐藏聊天标题和完整路径"),
                        isOn: $hidesAgentStoragePrivateDetails
                    )

                    Text(L10n.text("分析完全在本机进行；不会上传标题、路径或占用数据。"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let sources = agentStorage.snapshot?.sources, !sources.isEmpty {
                        ForEach(sources) { source in
                            LabeledContent {
                                Text(agentStoragePath(source.path))
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } label: {
                                Label(source.displayName, systemImage: {
                                    switch source.provider {
                                    case .codex: "terminal"
                                    case .claude: "sparkles"
                                    case .openCode: "curlybraces"
                                    }
                                }())
                            }
                        }
                    }

                    ForEach(agentStorage.customRoots, id: \.path) { root in
                        HStack {
                            Label(L10n.text("手动数据位置"), systemImage: "folder.badge.plus")
                            Spacer()
                            Text(agentStoragePath(root.path))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                agentStorage.removeCustomRoot(root)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .help(L10n.text("移除数据位置"))
                        }
                    }

                    HStack {
                        Button(action: addAgentStorageLocation) {
                            Label(L10n.text("添加数据位置"), systemImage: "folder.badge.plus")
                        }
                        Spacer()
                        Button {
                            agentStorage.isScanning ? agentStorage.stop() : agentStorage.startAnalysis()
                        } label: {
                            Label(
                                L10n.text(agentStorage.isScanning
                                    ? "停止本次扫描"
                                    : agentStorage.snapshot == nil ? "开始分析" : "重新分析"),
                                systemImage: agentStorage.isScanning ? "stop.fill" : "arrow.clockwise"
                            )
                        }
                    }

                    if let error = agentStorage.customRootError {
                        SettingsInlineStatus(
                            text: error,
                            systemImage: "exclamationmark.triangle",
                            color: .orange
                        )
                    }
                }

                Section(L10n.text("监测历史")) {
                    Toggle(
                        L10n.text("保存监测历史"),
                        isOn: Binding(
                            get: { history.configuration.isEnabled },
                            set: { value in
                                if value {
                                    Task { await history.setEnabled(true) }
                                } else {
                                    showsDisableHistoryOptions = true
                                }
                            }
                        )
                    )

                    Text(L10n.text("仅在本机保存聚合数据；每分钟批量写入一次，分钟明细保留 24 小时。"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    LabeledContent(L10n.text("保留时间")) {
                        Picker(
                            L10n.text("保留时间"),
                            selection: Binding(
                                get: { history.configuration.retention },
                                set: { requestRetention($0) }
                            )
                        ) {
                            ForEach(HistoryRetention.allCases) { retention in
                                Text(retention.localizedTitle).tag(retention)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }

                    Toggle(
                        L10n.text("保存应用级活动"),
                        isOn: Binding(
                            get: { history.configuration.savesApplicationActivity },
                            set: { value in
                                Task { await history.setApplicationActivityEnabled(value) }
                            }
                        )
                    )

                    Text(L10n.text("不会保存文件路径、PID、逐秒样本或深度追踪记录。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section(L10n.text("本地空间")) {
                    LabeledContent(L10n.text("最大占用")) {
                        Picker(
                            L10n.text("最大占用"),
                            selection: Binding(
                                get: { history.configuration.storageBudget },
                                set: { requestBudget($0) }
                            )
                        ) {
                            ForEach(HistoryStorageBudget.allCases) { budget in
                                Text(storageBudgetTitle(budget)).tag(budget)
                                    .disabled(!budgetIsFeasible(budget))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }

                    LabeledContent(
                        L10n.text("预计占用"),
                        value: estimatedStorageText
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent(
                            L10n.text("本地占用"),
                            value: storageUsageText
                        )
                        ProgressView(value: storageFraction)
                            .tint(storageTint)
                    }

                    LabeledContent(L10n.text("状态"), value: storageStateText)
                    LabeledContent(L10n.text("最近保存"), value: lastSavedText)

                    if let error = history.initializationError {
                        SettingsInlineStatus(
                            text: error,
                            systemImage: "exclamationmark.triangle",
                            color: .orange
                        )
                    }

                    Button(role: .destructive) {
                        confirmation = .clearSavedHistory
                    } label: {
                        Label(L10n.text("清除已保存历史"), systemImage: "trash")
                    }
                    .disabled(history.isClearing || history.storageInfo.totalBytes == 0)

                    if let databaseURL = history.databaseURL {
                        Button {
                            let target = FileManager.default.fileExists(atPath: databaseURL.path)
                                ? databaseURL
                                : databaseURL.deletingLastPathComponent()
                            NSWorkspace.shared.activateFileViewerSelecting([target])
                        } label: {
                            Label(L10n.text("在 Finder 中显示数据文件"), systemImage: "folder")
                        }
                    }
                }

                Section(L10n.text("实时会话")) {
                    Text(L10n.text("实时曲线仍只保留在内存中，退出应用后自动清除。"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(role: .destructive) {
                        store.clearHistory()
                        historyWasCleared = true
                    } label: {
                        Label(L10n.text("清除实时会话数据"), systemImage: "trash")
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

                case .softwareUpdate:
                    UpdaterSettingsSection(updates: updates)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(item: $confirmation, content: historySettingsAlert)
        .confirmationDialog(
            L10n.text("停止保存监测历史？"),
            isPresented: $showsDisableHistoryOptions,
            titleVisibility: .visible
        ) {
            Button(L10n.text("仅停止保存")) {
                Task { await history.setEnabled(false) }
            }
            Button(L10n.text("停止并删除已有历史"), role: .destructive) {
                Task {
                    await history.setEnabled(false)
                    await history.clearSavedHistory()
                }
            }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: {
            Text(L10n.text("已有历史可在停止保存后继续查看；删除后无法恢复。"))
        }
        .task {
            store.setSamplingInterval(sampleInterval)
            sampleInterval = store.samplingInterval
            refreshServiceStates()
            await history.refreshStorage()
        }
        .task(id: historyWasCleared) {
            guard historyWasCleared else { return }
            try? await Task.sleep(for: .seconds(3))
            historyWasCleared = false
        }
        .onChange(of: sampleInterval) { _, newValue in
            store.setSamplingInterval(newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshServiceStates()
        }
    }

    @ViewBuilder
    private func settingsPanePicker(style: SettingsPickerStyle) -> some View {
        let picker = Picker(L10n.text("设置类别"), selection: settingsPaneBinding) {
            ForEach(SettingsPane.allCases) { pane in
                Text(pane.title).tag(pane)
            }
        }
        switch style {
        case .segmented:
            picker.pickerStyle(.segmented)
        case .menu:
            picker.pickerStyle(.menu)
        }
    }

    private var settingsPaneBinding: Binding<SettingsPane> {
        Binding(
            get: { navigation.settingsPane },
            set: { navigation.settingsPane = $0 }
        )
    }

    private func addAgentStorageLocation() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择 AI Agent 数据位置")
        panel.prompt = L10n.text("添加")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        agentStorage.addCustomRoot(url)
    }

    private func agentStoragePath(_ path: String) -> String {
        hidesAgentStoragePrivateDetails ? L10n.text("路径已隐藏") : path
    }

    private var traceHelperCanBeRemoved: Bool {
        switch traceHelperState {
        case .notRegistered, .notFound:
            false
        default:
            true
        }
    }

    private var samplingIntervalBinding: Binding<Double> {
        Binding(
            get: { sampleInterval },
            set: { value in
                let normalized = MonitorStore.normalizedSamplingInterval(value)
                sampleInterval = normalized
                store.setSamplingInterval(normalized)
            }
        )
    }

    private var nodeRuntimeStatusColor: Color {
        switch nodeRuntime.phase {
        case .checking: .secondary
        case .available: .green
        case .missing: .orange
        case .downloading, .verifying, .installing: .blue
        case .failed: .red
        }
    }

    private var nodeRuntimeStatusText: String {
        switch nodeRuntime.phase {
        case .checking:
            L10n.text("检测中…")
        case .available(let availability):
            "\(availability.version) · \(availability.source.localizedLabel)"
        case .missing:
            L10n.text("未检测到可用运行时")
        case .downloading:
            L10n.text("正在下载官方运行时…")
        case .verifying:
            L10n.text("正在校验官方运行时…")
        case .installing:
            L10n.text("正在安装官方运行时…")
        case .failed:
            L10n.text("下载或验证失败")
        }
    }

    private var traceHelperStatusText: String {
        switch traceHelperState {
        case .notRegistered: L10n.text("未启用")
        case .requiresApproval: L10n.text("等待系统批准")
        case .enabled, .connecting, .ready: L10n.text("已启用")
        case .repairing: L10n.text("正在更新追踪组件")
        case .repairAvailable: L10n.text("追踪组件需要修复")
        case .installationRequired: L10n.text("需要先安装到应用程序文件夹")
        case .notFound: L10n.text("当前版本未包含")
        case .protocolMismatch: L10n.text("需要重新安装")
        case .connectionUnavailable: L10n.text("暂时无法连接")
        case .operationFailed: L10n.text("操作失败")
        }
    }

    private func refreshServiceStates() {
        loginItem.refresh()
        nodeRuntime.refresh()
        let controller = TraceHelperController()
        controller.refreshStatus()
        traceHelperState = controller.state
    }

    private func removeTraceHelper() {
        let controller = TraceHelperController()
        _ = controller.unregister()
        traceHelperState = controller.state
    }

    private func requestRetention(_ retention: HistoryRetention) {
        if retention.cutoffDays < history.configuration.retention.cutoffDays {
            confirmation = .retention(retention)
        } else {
            Task { await history.setRetention(retention) }
        }
    }

    private func requestBudget(_ budget: HistoryStorageBudget) {
        guard budgetIsFeasible(budget) else { return }
        let newLimit = budget.bytes(for: history.configuration.retention)
        let oldLimit = history.configuration.budgetBytes
        if newLimit < oldLimit || newLimit < history.storageInfo.totalBytes {
            confirmation = .budget(budget)
        } else {
            Task { await history.setStorageBudget(budget) }
        }
    }

    private func budgetIsFeasible(_ budget: HistoryStorageBudget) -> Bool {
        if budget == .automatic { return true }
        if history.configuration.retention == .oneYear, budget == .mb32 { return false }
        return budget.bytes(for: history.configuration.retention) >= 32_000_000
    }

    private func storageBudgetTitle(_ budget: HistoryStorageBudget) -> String {
        if budget == .automatic {
            return L10n.format(
                "自动（%@）",
                ByteRateFormatter.approximateBytes(Double(history.configuration.retention.automaticBudgetBytes))
            )
        }
        return ByteRateFormatter.approximateBytes(Double(budget.rawValue))
    }

    private var estimatedStorageText: String {
        let estimate = history.estimatedUsageRange
        return L10n.format(
            "压缩后约 %@ – %@",
            ByteRateFormatter.approximateBytes(Double(estimate.lowerBound)),
            ByteRateFormatter.approximateBytes(Double(estimate.upperBound))
        )
    }

    private var storageUsageText: String {
        "\(ByteRateFormatter.approximateBytes(Double(history.storageInfo.totalBytes))) / "
            + ByteRateFormatter.approximateBytes(Double(history.storageInfo.budgetBytes))
    }

    private var storageFraction: Double {
        guard history.storageInfo.budgetBytes > 0 else { return 0 }
        return min(1, Double(history.storageInfo.totalBytes) / Double(history.storageInfo.budgetBytes))
    }

    private var storageTint: Color {
        switch history.storageInfo.state {
        case .normal: .accentColor
        case .optimizing: .blue
        case .compacted, .nearingLimit: .orange
        case .paused, .unavailable: .red
        }
    }

    private var storageStateText: String {
        switch history.storageInfo.state {
        case .normal: L10n.text("正常")
        case .nearingLimit: L10n.text("接近上限")
        case .optimizing(let progress): L10n.format("正在优化 %.0f%%", progress * 100)
        case .compacted(let start): L10n.format(
            "%@ 以前的应用明细已精简",
            L10n.date(start, date: .abbreviated, time: .omitted)
        )
        case .paused: L10n.text("达到预算并暂停")
        case .unavailable: L10n.text("不可用")
        }
    }

    private var lastSavedText: String {
        guard let date = history.storageInfo.lastSavedAt else {
            return history.configuration.isEnabled
                ? L10n.text("等待首个分钟汇总")
                : L10n.text("尚未保存")
        }
        return L10n.date(date, date: .abbreviated, time: .shortened)
    }

    private func historySettingsAlert(_ confirmation: HistorySettingsConfirmation) -> Alert {
        switch confirmation {
        case .retention(let retention):
            return Alert(
                title: Text(L10n.text("缩短保留时间？")),
                message: Text(L10n.format(
                    "将删除超出 %@ 的聚合数据，此操作无法撤销。",
                    retention.localizedTitle
                )),
                primaryButton: .destructive(Text(L10n.text("缩短并删除"))) {
                    Task { await history.setRetention(retention) }
                },
                secondaryButton: .cancel(Text(L10n.text("取消")))
            )
        case .budget(let budget):
            let target = storageBudgetTitle(budget)
            return Alert(
                title: Text(L10n.text("降低最大占用？")),
                message: Text(L10n.format(
                    "当前占用 %@。降至 %@ 后，较早的应用趋势和日排名可能并入“其他”且无法恢复；若仍无法满足预算，历史保存会暂停。",
                    ByteRateFormatter.approximateBytes(Double(history.storageInfo.totalBytes)),
                    target
                )),
                primaryButton: .destructive(Text(L10n.text("降低并优化"))) {
                    Task { await history.setStorageBudget(budget) }
                },
                secondaryButton: .cancel(Text(L10n.text("取消")))
            )
        case .clearSavedHistory:
            return Alert(
                title: Text(L10n.text("清除已保存历史？")),
                message: Text(L10n.text("所有历史分析数据和应用排名将被永久删除，实时监测不受影响。")),
                primaryButton: .destructive(Text(L10n.text("清除历史"))) {
                    Task { await history.clearSavedHistory() }
                },
                secondaryButton: .cancel(Text(L10n.text("取消")))
            )
        }
    }
}

private enum HistorySettingsConfirmation: Identifiable {
    case retention(HistoryRetention)
    case budget(HistoryStorageBudget)
    case clearSavedHistory

    var id: String {
        switch self {
        case .retention(let value): "retention-\(value.rawValue)"
        case .budget(let value): "budget-\(value.rawValue)"
        case .clearSavedHistory: "clear"
        }
    }
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
