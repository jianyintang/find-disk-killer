import AppKit
import Observation
import Sparkle

enum UpdateBlockAction: Equatable {
    case openInstallationLocation
}

@MainActor
@Observable
final class UpdateCoordinator: NSObject, SPUUpdaterDelegate {
    private(set) var isConfigured = false
    private(set) var isChecking = false
    private(set) var configurationMessage: String?

    @ObservationIgnored private var updaterController: SPUStandardUpdaterController!
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private let activityRegistry: TraceActivityRegistry
    @ObservationIgnored private let bundle: Bundle
    @ObservationIgnored private var pendingManualLease: UpdateActivityLease?
    @ObservationIgnored private var activeLease: UpdateActivityLease?
    @ObservationIgnored private var hasStartedUpdater = false

    init(activityRegistry: TraceActivityRegistry, bundle: Bundle = .main) {
        self.activityRegistry = activityRegistry
        self.bundle = bundle
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        validateConfiguration()
        canCheckObservation = updaterController.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor in self?.refreshState() }
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    func start() {
        guard isConfigured, !hasStartedUpdater else { return }
        hasStartedUpdater = true
        updaterController.startUpdater()
    }

    var canCheckForUpdates: Bool {
        isConfigured
            && isInstalledInApplications
            && !isChecking
            && updaterController.updater.canCheckForUpdates
            && !updaterController.updater.sessionInProgress
            && activityRegistry.canStartUpdate
    }

    var requiresInstallation: Bool {
        isConfigured && !isInstalledInApplications
    }

    var blockAction: UpdateBlockAction? {
        requiresInstallation ? .openInstallationLocation : nil
    }

    var blockReason: String? {
        if !isConfigured {
            return configurationMessage ?? L10n.text("当前构建尚未配置软件更新")
        }
        if !isInstalledInApplications {
            return L10n.text("请先将 FindDiskKiller 移到“应用程序”文件夹")
        }
        switch activityRegistry.status {
        case .traceStartingOrRunning:
            return L10n.text("结束追踪后可检查更新")
        case .traceStopping, .stopUnconfirmed:
            return L10n.text("正在确认追踪已结束，请稍后重试")
        case .updatePendingOrRunning:
            return L10n.text("正在检查或安装更新")
        case .idle:
            return nil
        }
    }

    func checkForUpdates() {
        guard updaterController.updater.canCheckForUpdates,
              !updaterController.updater.sessionInProgress,
              isConfigured,
              isInstalledInApplications,
              let lease = activityRegistry.reserveUpdate()
        else { return }

        pendingManualLease = lease
        isChecking = true
        updaterController.checkForUpdates(nil)

        if !updaterController.updater.sessionInProgress {
            pendingManualLease = nil
            activityRegistry.releaseUpdate(lease)
            isChecking = false
        }
    }

    func openInstallationLocation() {
        let bundleURL = bundle.bundleURL
        if bundleURL.pathComponents.count >= 3, bundleURL.pathComponents[1] == "Volumes" {
            NSWorkspace.shared.open(URL(
                fileURLWithPath: "/Volumes/\(bundleURL.pathComponents[2])",
                isDirectory: true
            ))
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
    }

    func updater(
        _ updater: SPUUpdater,
        mayPerform updateCheck: SPUUpdateCheck
    ) throws {
        let lease: UpdateActivityLease?
        if updateCheck == .updates {
            lease = pendingManualLease
            pendingManualLease = nil
        } else {
            lease = activityRegistry.reserveUpdate()
        }
        guard let lease else {
            throw NSError(
                domain: "com.jianyintang.FindDiskKiller.Update",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: blockReason
                    ?? L10n.text("当前无法检查更新")]
            )
        }
        activeLease = lease
        isChecking = true
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        releaseUpdateLeases()
    }

    private func validateConfiguration() {
        guard let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let keyData = Data(base64Encoded: key),
              keyData.count == 32
        else {
            configurationMessage = L10n.text("当前构建缺少有效的 Sparkle 公钥")
            return
        }
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              URL(string: feed) != nil
        else {
            configurationMessage = L10n.text("当前构建缺少有效的更新地址")
            return
        }
        isConfigured = true
    }

    private func releaseUpdateLeases() {
        if let activeLease {
            activityRegistry.releaseUpdate(activeLease)
        }
        if let pendingManualLease {
            activityRegistry.releaseUpdate(pendingManualLease)
        }
        activeLease = nil
        pendingManualLease = nil
        isChecking = false
        refreshState()
    }

    private func refreshState() {
        if !updaterController.updater.sessionInProgress, activeLease == nil,
           pendingManualLease == nil {
            isChecking = false
        }
    }

    private var isInstalledInApplications: Bool {
        let path = bundle.bundleURL.standardizedFileURL.path
        return path == "/Applications" || path.hasPrefix("/Applications/")
    }
}
