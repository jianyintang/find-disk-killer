import Foundation
import Testing
@testable import FindDiskKillerCore

@Test func historyIdentityUsesBundleIdentifiersWithoutPersistingPaths() {
    let provider = HistoryIdentityProvider(keyStore: MemoryIdentityKeyStore())
    let identity = provider.applicationIdentity(
        bundleIdentifier: "com.example.Editor",
        fallbackIdentity: "/Applications/Editor.app/Contents/MacOS/Editor"
    )
    #expect(identity == "bundle:com.example.Editor")
    #expect(!identity.contains("/Applications"))
}

@Test func historyIdentityHMACChangesAfterTheInstallationKeyRotates() throws {
    let store = MemoryIdentityKeyStore()
    let provider = HistoryIdentityProvider(keyStore: store)
    let first = provider.applicationIdentity(bundleIdentifier: nil, fallbackIdentity: "/usr/bin/tool")
    try provider.rotate()
    let second = provider.applicationIdentity(bundleIdentifier: nil, fallbackIdentity: "/usr/bin/tool")

    #expect(first.hasPrefix("hmac:"))
    #expect(first != second)
    #expect(!first.contains("/usr/bin/tool"))
}

@Test func historyFileIdentityKeyPersistsWithOwnerOnlyProtection() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let keyURL = root
        .appending(path: "History", directoryHint: .isDirectory)
        .appending(path: "identity-key-v1", directoryHint: .notDirectory)
    let store = HistoryFileKeyStore(keyURL: keyURL)

    let firstProvider = HistoryIdentityProvider(keyStore: store)
    let firstIdentity = firstProvider.applicationIdentity(
        bundleIdentifier: nil,
        fallbackIdentity: "/usr/bin/tool"
    )
    let savedKey = try Data(contentsOf: keyURL)
    let secondProvider = HistoryIdentityProvider(keyStore: store)
    let secondIdentity = secondProvider.applicationIdentity(
        bundleIdentifier: nil,
        fallbackIdentity: "/usr/bin/tool"
    )

    let directory = keyURL.deletingLastPathComponent()
    let directoryMode = try #require(
        FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
            as? NSNumber
    )
    let keyMode = try #require(
        FileManager.default.attributesOfItem(atPath: keyURL.path)[.posixPermissions]
            as? NSNumber
    )
    let resourceValues = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(savedKey.count == 32)
    #expect(firstIdentity == secondIdentity)
    #expect(directoryMode.intValue & 0o777 == 0o700)
    #expect(keyMode.intValue & 0o777 == 0o600)
    #expect(resourceValues.isExcludedFromBackup == true)
}

@Test func historyFileIdentityRotationReplacesThePersistedKey() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let keyURL = root
        .appending(path: "History", directoryHint: .isDirectory)
        .appending(path: "identity-key-v1", directoryHint: .notDirectory)
    let provider = HistoryIdentityProvider(keyStore: HistoryFileKeyStore(keyURL: keyURL))
    let firstKey = try Data(contentsOf: keyURL)
    let firstIdentity = provider.applicationIdentity(
        bundleIdentifier: nil,
        fallbackIdentity: "/usr/bin/tool"
    )

    try provider.rotate()

    let secondKey = try Data(contentsOf: keyURL)
    let secondIdentity = provider.applicationIdentity(
        bundleIdentifier: nil,
        fallbackIdentity: "/usr/bin/tool"
    )
    #expect(firstKey != secondKey)
    #expect(firstIdentity != secondIdentity)
    #expect(secondKey.count == 32)
}

@Test func historyIdentityDefaultPathSeparatesProductionFromTestProcesses() {
    let applicationSupport = URL(filePath: "/Users/example/Library/Application Support")
    let temporaryDirectory = URL(filePath: "/private/tmp")

    let production = HistoryFileKeyStore.defaultKeyURL(
        bundleIdentifier: HistoryFileKeyStore.productionBundleIdentifier,
        applicationSupportURL: applicationSupport,
        temporaryDirectory: temporaryDirectory,
        processIdentifier: 42
    )
    let test = HistoryFileKeyStore.defaultKeyURL(
        bundleIdentifier: "com.apple.dt.xctest.tool",
        applicationSupportURL: applicationSupport,
        temporaryDirectory: temporaryDirectory,
        processIdentifier: 42
    )

    #expect(production.path == "/Users/example/Library/Application Support/com.jianyintang.FindDiskKiller/History/identity-key-v1")
    #expect(test.path == "/private/tmp/FindDiskKiller-42/History/identity-key-v1")
}

@Test func historyFileIdentityLoadRepairsExistingProtection() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: "History", directoryHint: .isDirectory)
    let keyURL = directory.appending(path: "identity-key-v1", directoryHint: .notDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(repeating: 7, count: 32).write(to: keyURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: keyURL.path)

    _ = try HistoryFileKeyStore(keyURL: keyURL).loadKey()

    let directoryMode = try #require(
        FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
            as? NSNumber
    )
    let keyMode = try #require(
        FileManager.default.attributesOfItem(atPath: keyURL.path)[.posixPermissions]
            as? NSNumber
    )
    let resourceValues = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(directoryMode.intValue & 0o777 == 0o700)
    #expect(keyMode.intValue & 0o777 == 0o600)
    #expect(resourceValues.isExcludedFromBackup == true)
}

@Test func historyIdentityStorageFailuresAreReportedToTheDatabase() {
    let loadFailure = MemoryIdentityKeyStore()
    loadFailure.failLoads = true
    let loadProvider = HistoryIdentityProvider(keyStore: loadFailure)
    #expect(throws: HistoryIdentityStorageError.self) {
        try loadProvider.validate()
    }

    let saveFailure = MemoryIdentityKeyStore()
    saveFailure.failSaves = true
    let saveProvider = HistoryIdentityProvider(keyStore: saveFailure)
    #expect(throws: HistoryIdentityStorageError.self) {
        _ = try HistoryDatabase(
            location: .memory,
            fileOperations: LiveHistoryFileOperations(),
            identityProvider: saveProvider
        )
    }
}

@Test func historyIdentityRotationsRemainAtomicAcrossConcurrentCallers() async throws {
    let store = ConcurrentSaveTrackingKeyStore()
    let provider = HistoryIdentityProvider(keyStore: store)
    store.resetTracking()

    let tasks = (0..<8).map { _ in
        Task.detached { try provider.rotate() }
    }
    for task in tasks {
        try await task.value
    }

    let currentIdentity = provider.applicationIdentity(
        bundleIdentifier: nil,
        fallbackIdentity: "/usr/bin/tool"
    )
    let reloadedIdentity = HistoryIdentityProvider(keyStore: store).applicationIdentity(
        bundleIdentifier: nil,
        fallbackIdentity: "/usr/bin/tool"
    )
    #expect(store.maximumConcurrentSaves == 1)
    #expect(currentIdentity == reloadedIdentity)
}

@MainActor
@Test func monitorStoreUsesBundleIdentityAndHMACDeviceIdentity() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundleURL = root.appending(path: "Editor.app", directoryHint: .isDirectory)
    let contentsURL = bundleURL.appending(path: "Contents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(
        fromPropertyList: [
            "CFBundleIdentifier": "com.example.Editor",
            "CFBundleExecutable": "Editor"
        ],
        format: .xml,
        options: 0
    )
    try plist.write(to: contentsURL.appending(path: "Info.plist"))

    let provider = RecordingHistoryIdentityProvider()
    let store = MonitorStore(
        sampleProvider: { .identityFixture(at: .now, counter: 0, executablePath: "") },
        historyIdentityProvider: provider
    )
    let executablePath = contentsURL.appending(path: "MacOS/Editor").path
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    store.ingest(.identityFixture(at: start, counter: 100, executablePath: executablePath))
    store.ingest(.identityFixture(
        at: start.addingTimeInterval(1),
        counter: 142,
        executablePath: executablePath
    ))

    #expect(provider.applicationCalls == [
        .init(bundleIdentifier: "com.example.Editor", fallbackIdentity: "app:\(bundleURL.path)")
    ])
    #expect(provider.deviceCalls == [.init(registryID: 99, bsdName: "disk99")])
}

@Test func historyDatabaseCreatesOwnerOnlyNoBackupFiles() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "History/monitor.sqlite3")
    let database = try HistoryDatabase(location: .file(url))
    let recorder = HistoryRecorder(database: database)
    await recorder.record(.identityFixture(
        at: Date(timeIntervalSince1970: 1_800_000_000),
        diskWriteBytes: 42
    ))
    await recorder.flush()

    let directory = url.deletingLastPathComponent()
    let directoryMode = try #require(
        FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
            as? NSNumber
    )
    let databaseMode = try #require(
        FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
            as? NSNumber
    )
    let resourceValues = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(directoryMode.intValue & 0o777 == 0o700)
    #expect(databaseMode.intValue & 0o777 == 0o600)
    #expect(resourceValues.isExcludedFromBackup == true)
    for sidecar in ["-wal", "-shm"] {
        let sidecarURL = URL(fileURLWithPath: url.path + sidecar)
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else { continue }
        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: sidecarURL.path)[.posixPermissions]
                as? NSNumber
        )
        #expect(mode.intValue & 0o777 == 0o600)
    }
}

@Test func historyDatabaseInitializationPropagatesProtectionFailures() {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "History/monitor.sqlite3")

    #expect(throws: FixtureFileError.self) {
        _ = try HistoryDatabase(
            location: .file(url),
            fileOperations: FailingHistoryFileOperations(failure: .permissions),
            identityProvider: HistoryIdentityProvider(keyStore: MemoryIdentityKeyStore())
        )
    }
    #expect(throws: FixtureFileError.self) {
        _ = try HistoryDatabase(
            location: .file(url),
            fileOperations: FailingHistoryFileOperations(failure: .noBackup),
            identityProvider: HistoryIdentityProvider(keyStore: MemoryIdentityKeyStore())
        )
    }
}

@Test func clearingHistoryDeletesAndRebuildsTheDatabaseThenRotatesIdentity() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "monitor.sqlite3")
    let keyStore = MemoryIdentityKeyStore()
    let provider = HistoryIdentityProvider(keyStore: keyStore)
    let database = try HistoryDatabase(
        location: .file(url),
        fileOperations: LiveHistoryFileOperations(),
        identityProvider: provider
    )
    let recorder = HistoryRecorder(database: database)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    await recorder.record(.identityFixture(at: start, diskWriteBytes: 42))
    await recorder.flush()
    let oldFileNumber = try #require(
        FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
    )
    let oldIdentity = provider.applicationIdentity(bundleIdentifier: nil, fallbackIdentity: "/usr/bin/tool")

    try await database.clear()

    let newFileNumber = try #require(
        FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
    )
    let newIdentity = provider.applicationIdentity(bundleIdentifier: nil, fallbackIdentity: "/usr/bin/tool")
    let report = try await database.report(range: .sevenDays, now: start.addingTimeInterval(60))
    #expect(oldFileNumber != newFileNumber)
    #expect(oldIdentity != newIdentity)
    #expect(report.summary.diskWriteBytes == 0)

    await recorder.record(.identityFixture(
        at: start.addingTimeInterval(60),
        diskWriteBytes: 7
    ))
    await recorder.flush()
    let rebuiltReport = try await database.report(
        range: .sevenDays,
        now: start.addingTimeInterval(120)
    )
    #expect(rebuiltReport.summary.diskWriteBytes == 7)
}

@Test func clearFailurePreservesDataAndDoesNotRotateIdentity() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "monitor.sqlite3")
    let operations = ControllableHistoryFileOperations()
    let provider = HistoryIdentityProvider(keyStore: MemoryIdentityKeyStore())
    let database = try HistoryDatabase(
        location: .file(url),
        fileOperations: operations,
        identityProvider: provider
    )
    let recorder = HistoryRecorder(database: database)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    await recorder.record(.identityFixture(at: start, diskWriteBytes: 42))
    await recorder.flush()
    let oldIdentity = provider.applicationIdentity(bundleIdentifier: nil, fallbackIdentity: "/usr/bin/tool")
    operations.failRemoval = true

    await #expect(throws: FixtureFileError.self) {
        try await database.clear()
    }

    let report = try await database.report(range: .sevenDays, now: start.addingTimeInterval(60))
    let currentIdentity = provider.applicationIdentity(bundleIdentifier: nil, fallbackIdentity: "/usr/bin/tool")
    #expect(report.summary.diskWriteBytes == 42)
    #expect(currentIdentity == oldIdentity)
}

@Test func identityRotationFailureIsReportedAfterTheDatabaseIsCleared() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "monitor.sqlite3")
    let keyStore = MemoryIdentityKeyStore()
    let provider = HistoryIdentityProvider(keyStore: keyStore)
    let database = try HistoryDatabase(
        location: .file(url),
        fileOperations: LiveHistoryFileOperations(),
        identityProvider: provider
    )
    let recorder = HistoryRecorder(database: database)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    await recorder.record(.identityFixture(at: start, diskWriteBytes: 42))
    await recorder.flush()
    let oldIdentity = provider.applicationIdentity(bundleIdentifier: nil, fallbackIdentity: "/usr/bin/tool")
    keyStore.failSaves = true

    await #expect(throws: FixtureKeyError.self) {
        try await database.clear()
    }

    let report = try await database.report(range: .sevenDays, now: start.addingTimeInterval(60))
    let currentIdentity = provider.applicationIdentity(bundleIdentifier: nil, fallbackIdentity: "/usr/bin/tool")
    #expect(report.summary.diskWriteBytes == 0)
    #expect(currentIdentity == oldIdentity)
}

@Test func runtimePermissionFailureIsSurfacedAsUnavailable() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "monitor.sqlite3")
    let operations = ControllableHistoryFileOperations()
    let database = try HistoryDatabase(
        location: .file(url),
        fileOperations: operations,
        identityProvider: HistoryIdentityProvider(keyStore: MemoryIdentityKeyStore())
    )
    operations.failPermissions = true
    let recorder = HistoryRecorder(database: database)
    await recorder.record(.identityFixture(
        at: Date(timeIntervalSince1970: 1_800_000_000),
        diskWriteBytes: 42
    ))
    await recorder.flush()

    let storage = await database.storageInfo(configuration: .init(isEnabled: true))
    guard case .unavailable = storage.state else {
        Issue.record("Permission failure was not surfaced")
        return
    }
}

@Test func clearingThroughRecorderDiscardsUncommittedHistory() async throws {
    let provider = HistoryIdentityProvider(keyStore: MemoryIdentityKeyStore())
    let database = try HistoryDatabase(
        location: .memory,
        fileOperations: LiveHistoryFileOperations(),
        identityProvider: provider
    )
    let recorder = HistoryRecorder(database: database)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    await recorder.record(.identityFixture(at: start, diskWriteBytes: 42))

    try await recorder.clear()
    await recorder.flush()

    let report = try await database.report(range: .sevenDays, now: start.addingTimeInterval(60))
    #expect(report.summary.diskWriteBytes == 0)
}

private final class MemoryIdentityKeyStore: HistoryIdentityKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?
    private var shouldFailLoads = false
    private var shouldFailSaves = false

    var failLoads: Bool {
        get { lock.withLock { shouldFailLoads } }
        set { lock.withLock { shouldFailLoads = newValue } }
    }

    var failSaves: Bool {
        get { lock.withLock { shouldFailSaves } }
        set { lock.withLock { shouldFailSaves = newValue } }
    }

    func loadKey() throws -> Data? {
        try lock.withLock {
            if shouldFailLoads { throw FixtureKeyError.failed }
            return key
        }
    }
    func saveKey(_ key: Data) throws {
        try lock.withLock {
            if shouldFailSaves { throw FixtureKeyError.failed }
            self.key = key
        }
    }
}

private final class ConcurrentSaveTrackingKeyStore: HistoryIdentityKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?
    private var activeSaveCount = 0
    private var recordedMaximumConcurrentSaves = 0

    var maximumConcurrentSaves: Int {
        lock.withLock { recordedMaximumConcurrentSaves }
    }

    func resetTracking() {
        lock.withLock { recordedMaximumConcurrentSaves = 0 }
    }

    func loadKey() throws -> Data? { lock.withLock { key } }

    func saveKey(_ key: Data) throws {
        lock.withLock {
            activeSaveCount += 1
            recordedMaximumConcurrentSaves = max(recordedMaximumConcurrentSaves, activeSaveCount)
        }
        Thread.sleep(forTimeInterval: 0.01)
        lock.withLock {
            self.key = key
            activeSaveCount -= 1
        }
    }
}

private final class RecordingHistoryIdentityProvider: HistoryIdentityProviding, @unchecked Sendable {
    struct ApplicationCall: Equatable {
        let bundleIdentifier: String?
        let fallbackIdentity: String
    }

    struct DeviceCall: Equatable {
        let registryID: UInt64
        let bsdName: String
    }

    private let lock = NSLock()
    private var recordedApplicationCalls: [ApplicationCall] = []
    private var recordedDeviceCalls: [DeviceCall] = []

    var applicationCalls: [ApplicationCall] { lock.withLock { recordedApplicationCalls } }
    var deviceCalls: [DeviceCall] { lock.withLock { recordedDeviceCalls } }

    func applicationIdentity(bundleIdentifier: String?, fallbackIdentity: String) -> String {
        lock.withLock {
            recordedApplicationCalls.append(.init(
                bundleIdentifier: bundleIdentifier,
                fallbackIdentity: fallbackIdentity
            ))
        }
        return bundleIdentifier.map { "bundle:\($0)" } ?? "application-hmac"
    }

    func deviceIdentity(registryID: UInt64, bsdName: String) -> String {
        lock.withLock { recordedDeviceCalls.append(.init(registryID: registryID, bsdName: bsdName)) }
        return "device-hmac"
    }

    func rotate() throws {}
}

private enum FixtureFileError: Error {
    case failed
}

private enum FixtureKeyError: Error {
    case failed
}

private struct FailingHistoryFileOperations: HistoryFileOperating {
    enum Failure: Equatable {
        case permissions
        case noBackup
    }

    let failure: Failure
    private let live = LiveHistoryFileOperations()

    func createDirectory(at url: URL) throws { try live.createDirectory(at: url) }

    func setPermissions(_ permissions: Int, at url: URL) throws {
        if failure == .permissions { throw FixtureFileError.failed }
        try live.setPermissions(permissions, at: url)
    }

    func excludeFromBackup(_ url: URL) throws {
        if failure == .noBackup { throw FixtureFileError.failed }
        try live.excludeFromBackup(url)
    }

    func fileExists(at url: URL) -> Bool { live.fileExists(at: url) }
    func removeItem(at url: URL) throws { try live.removeItem(at: url) }
    func fileSize(at url: URL) -> Int64 { live.fileSize(at: url) }
}

private final class ControllableHistoryFileOperations: HistoryFileOperating, @unchecked Sendable {
    private let live = LiveHistoryFileOperations()
    private let lock = NSLock()
    private var shouldFailRemoval = false
    private var shouldFailPermissions = false

    var failRemoval: Bool {
        get { lock.withLock { shouldFailRemoval } }
        set { lock.withLock { shouldFailRemoval = newValue } }
    }

    var failPermissions: Bool {
        get { lock.withLock { shouldFailPermissions } }
        set { lock.withLock { shouldFailPermissions = newValue } }
    }

    func createDirectory(at url: URL) throws { try live.createDirectory(at: url) }
    func setPermissions(_ permissions: Int, at url: URL) throws {
        if failPermissions, url.pathExtension == "sqlite3" { throw FixtureFileError.failed }
        try live.setPermissions(permissions, at: url)
    }
    func excludeFromBackup(_ url: URL) throws { try live.excludeFromBackup(url) }
    func fileExists(at url: URL) -> Bool { live.fileExists(at: url) }
    func removeItem(at url: URL) throws {
        if failRemoval, url.pathExtension == "sqlite3" { throw FixtureFileError.failed }
        try live.removeItem(at: url)
    }
    func fileSize(at url: URL) -> Int64 { live.fileSize(at: url) }
}

private extension SystemSnapshot {
    static func identityFixture(at date: Date, counter: UInt64, executablePath: String) -> Self {
        Self(
            date: date,
            uptime: TimeInterval(counter),
            processes: [RawProcessCounter(
                pid: 42,
                startAbstime: 7,
                name: "Editor",
                path: executablePath,
                cpuTimeNanoseconds: counter * 1_000_000,
                bytesRead: counter,
                bytesWritten: counter,
                networkBytesReceived: counter,
                networkBytesSent: counter
            )],
            disks: [RawDiskCounter(
                registryID: 99,
                name: "Physical Disk",
                bytesRead: counter,
                bytesWritten: counter,
                readOperations: counter,
                writeOperations: counter,
                capacity: 1_000_000,
                bsdName: "disk99",
                isPhysical: true
            )],
            volumes: [],
            cpuUserTicks: counter,
            cpuSystemTicks: 0,
            cpuNiceTicks: 0,
            cpuIdleTicks: counter * 9,
            networkInterfaces: [],
            cpuStatsAvailable: true,
            networkInterfacesAvailable: false,
            processNetworkAvailable: true
        )
    }
}

private extension HistorySample {
    static func identityFixture(at date: Date, diskWriteBytes: UInt64) -> Self {
        Self(
            timestamp: date,
            duration: 60,
            diskReadBytes: 0,
            diskWriteBytes: diskWriteBytes,
            cpuPercent: 0,
            networkReceiveBytes: 0,
            networkSendBytes: 0,
            applications: [],
            devices: []
        )
    }
}
