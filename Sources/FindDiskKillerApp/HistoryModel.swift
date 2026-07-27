import Foundation
import FindDiskKillerCore
import Observation

enum HistoryReportLoadState {
    case idle
    case loading
    case loaded(HistoryReport)
    case failed(String)
}

@MainActor
@Observable
final class HistoryModel {
    private(set) var configuration: HistoryConfiguration
    private(set) var storageInfo: HistoryStorageInfo
    private(set) var reportState: HistoryReportLoadState = .idle
    private(set) var isClearing = false
    private(set) var initializationError: String?

    let recorder: HistoryRecorder?
    private(set) var databaseURL: URL?
    private let database: HistoryDatabase?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, databaseURL: URL? = nil) {
        self.defaults = defaults
        let loadedConfiguration = Self.loadConfiguration(defaults: defaults)
        configuration = loadedConfiguration
        let budget = loadedConfiguration.budgetBytes
        storageInfo = HistoryStorageInfo(
            databaseBytes: 0,
            walBytes: 0,
            shmBytes: 0,
            budgetBytes: budget,
            lastSavedAt: nil,
            state: .normal
        )

        do {
            let url = try databaseURL ?? Self.defaultDatabaseURL()
            self.databaseURL = url
            let database = try HistoryDatabase(location: .file(url))
            self.database = database
            recorder = HistoryRecorder(database: database, configuration: loadedConfiguration)
        } catch {
            self.databaseURL = databaseURL
            database = nil
            recorder = nil
            initializationError = error.localizedDescription
            storageInfo = HistoryStorageInfo(
                databaseBytes: 0,
                walBytes: 0,
                shmBytes: 0,
                budgetBytes: budget,
                lastSavedAt: nil,
                state: .unavailable(error.localizedDescription)
            )
        }
    }

    func start(with store: MonitorStore) async {
        guard let recorder else { return }
        store.attachHistoryRecorder(recorder)
        await recorder.updateConfiguration(configuration)
        _ = try? await database?.performRetentionMaintenance(configuration: configuration)
        await refreshStorage()
    }

    func setEnabled(_ value: Bool) async {
        configuration.isEnabled = value
        saveConfiguration()
        await recorder?.updateConfiguration(configuration)
        await refreshStorage()
    }

    func setRetention(_ value: HistoryRetention) async {
        configuration.retention = value
        saveConfiguration()
        await recorder?.updateConfiguration(configuration)
        _ = try? await database?.performRetentionMaintenance(configuration: configuration)
        await refreshStorage()
    }

    func setStorageBudget(_ value: HistoryStorageBudget) async {
        configuration.storageBudget = value
        saveConfiguration()
        await recorder?.updateConfiguration(configuration)
        await refreshStorage()
    }

    func setApplicationActivityEnabled(_ value: Bool) async {
        configuration.savesApplicationActivity = value
        saveConfiguration()
        await recorder?.updateConfiguration(configuration)
    }

    func loadReport(range: HistoryRetention) async {
        guard let database else {
            reportState = .failed(initializationError ?? L10n.text("历史数据库不可用"))
            return
        }
        reportState = .loading
        do {
            let report = try await database.report(range: range)
            guard !Task.isCancelled else { return }
            reportState = .loaded(report)
            storageInfo = await database.storageInfo(configuration: configuration)
        } catch is CancellationError {
            return
        } catch {
            reportState = .failed(error.localizedDescription)
        }
    }

    func refreshStorage() async {
        guard let database else { return }
        storageInfo = await database.storageInfo(configuration: configuration)
    }

    func flush() async {
        await recorder?.flush()
        await refreshStorage()
    }

    func clearSavedHistory() async {
        guard let database else { return }
        isClearing = true
        defer { isClearing = false }
        do {
            if let recorder {
                try await recorder.clear()
            } else {
                try await database.clear()
            }
            reportState = .idle
            storageInfo = await database.storageInfo(configuration: configuration)
        } catch {
            initializationError = error.localizedDescription
        }
    }

    var estimatedUsageRange: ClosedRange<Int64> {
        switch configuration.retention {
        case .sevenDays: 8_000_000...20_000_000
        case .thirtyDays: 20_000_000...45_000_000
        case .oneYear: 55_000_000...100_000_000
        }
    }

    private func saveConfiguration() {
        defaults.set(configuration.isEnabled, forKey: "history.enabled")
        defaults.set(configuration.retention.rawValue, forKey: "history.retention")
        defaults.set(configuration.storageBudget.rawValue, forKey: "history.storageBudget")
        defaults.set(configuration.savesApplicationActivity, forKey: "history.saveApplications")
    }

    private static func loadConfiguration(defaults: UserDefaults) -> HistoryConfiguration {
        let retention = defaults.string(forKey: "history.retention")
            .flatMap(HistoryRetention.init(rawValue:)) ?? .thirtyDays
        let rawBudget = defaults.object(forKey: "history.storageBudget") as? NSNumber
        let budget = rawBudget.flatMap { HistoryStorageBudget(rawValue: $0.int64Value) } ?? .automatic
        let savesApps = defaults.object(forKey: "history.saveApplications") == nil
            ? true
            : defaults.bool(forKey: "history.saveApplications")
        return HistoryConfiguration(
            isEnabled: defaults.bool(forKey: "history.enabled"),
            retention: retention,
            storageBudget: budget,
            savesApplicationActivity: savesApps
        )
    }

    private static func defaultDatabaseURL() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return root
            .appending(path: "com.jianyintang.FindDiskKiller", directoryHint: .isDirectory)
            .appending(path: "History", directoryHint: .isDirectory)
            .appending(path: "monitor.sqlite3", directoryHint: .notDirectory)
    }
}
