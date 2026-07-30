import CryptoKit
import Darwin
import Foundation

protocol HistoryIdentityProviding: Sendable {
    func applicationIdentity(bundleIdentifier: String?, fallbackIdentity: String) -> String
    func deviceIdentity(registryID: UInt64, bsdName: String) -> String
    func rotate() throws
    func validate() throws
}

enum HistoryApplicationIdentity {
    static func stableFallback(processName: String) -> String {
        let normalized = processName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        return "process-name:\(normalized.isEmpty ? "unknown" : normalized)"
    }
}

extension HistoryIdentityProviding {
    func validate() throws {}
}

protocol HistoryIdentityKeyStoring: Sendable {
    func loadKey() throws -> Data?
    func saveKey(_ key: Data) throws
}

struct HistoryFileKeyStore: HistoryIdentityKeyStoring {
    static let productionBundleIdentifier = "com.jianyintang.FindDiskKiller"
    static let keyFileName = "identity-key-v1"

    let keyURL: URL

    init(keyURL: URL = Self.defaultKeyURL()) {
        self.keyURL = keyURL
    }

    func loadKey() throws -> Data? {
        guard FileManager.default.fileExists(atPath: keyURL.path) else { return nil }
        try protectContainer()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: keyURL.path
        )
        return try Data(contentsOf: keyURL)
    }

    func saveKey(_ key: Data) throws {
        try protectContainer()
        let temporaryURL = keyURL.deletingLastPathComponent().appending(
            path: ".\(keyURL.lastPathComponent).\(UUID().uuidString).tmp",
            directoryHint: .notDirectory
        )
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.write(contentsOf: key)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporaryURL.path
        )
        guard Darwin.rename(temporaryURL.path, keyURL.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func defaultKeyURL(
        bundleIdentifier: String?,
        applicationSupportURL: URL,
        temporaryDirectory: URL,
        processIdentifier: Int32
    ) -> URL {
        let directory = storageDirectory(
            bundleIdentifier: bundleIdentifier,
            applicationSupportURL: applicationSupportURL,
            temporaryDirectory: temporaryDirectory,
            processIdentifier: processIdentifier
        )
        return directory.appending(path: keyFileName, directoryHint: .notDirectory)
    }

    private func protectContainer() throws {
        let directory = keyURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        var protectedDirectory = directory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(resourceValues)
    }

    private static func defaultKeyURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let applicationSupport = home
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
        return defaultKeyURL(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            applicationSupportURL: applicationSupport,
            temporaryDirectory: FileManager.default.temporaryDirectory,
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        )
    }

    private static func storageDirectory(
        bundleIdentifier: String?,
        applicationSupportURL: URL,
        temporaryDirectory: URL,
        processIdentifier: Int32
    ) -> URL {
        let directory: URL
        if bundleIdentifier == productionBundleIdentifier {
            directory = applicationSupportURL
                .appending(path: productionBundleIdentifier, directoryHint: .isDirectory)
                .appending(path: "History", directoryHint: .isDirectory)
        } else {
            directory = temporaryDirectory
                .appending(
                    path: "FindDiskKiller-\(processIdentifier)",
                    directoryHint: .isDirectory
                )
                .appending(path: "History", directoryHint: .isDirectory)
        }
        return directory
    }
}

struct HistoryIdentityStorageError: Error, LocalizedError, Sendable {
    var errorDescription: String? {
        "Unable to protect the local monitoring identity"
    }
}

final class HistoryIdentityProvider: HistoryIdentityProviding, @unchecked Sendable {
    static let shared = HistoryIdentityProvider()

    private let lock = NSLock()
    private let keyStore: any HistoryIdentityKeyStoring
    private let initializationError: HistoryIdentityStorageError?
    private var key: Data

    init(keyStore: any HistoryIdentityKeyStoring = HistoryFileKeyStore()) {
        self.keyStore = keyStore
        do {
            if let saved = try keyStore.loadKey(), saved.count == 32 {
                key = saved
            } else {
                let generated = Self.randomKey()
                try keyStore.saveKey(generated)
                key = generated
            }
            initializationError = nil
        } catch {
            let generated = Self.randomKey()
            key = generated
            initializationError = HistoryIdentityStorageError()
        }
    }

    func applicationIdentity(bundleIdentifier: String?, fallbackIdentity: String) -> String {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return "bundle:\(bundleIdentifier)"
        }
        return "hmac:\(digest("app:\(fallbackIdentity)"))"
    }

    func deviceIdentity(registryID: UInt64, bsdName: String) -> String {
        digest("device:\(registryID):\(bsdName)")
    }

    func rotate() throws {
        try validate()
        try lock.withLock {
            let replacement = Self.randomKey()
            try keyStore.saveKey(replacement)
            key = replacement
        }
    }

    func validate() throws {
        if let initializationError { throw initializationError }
    }

    private func digest(_ value: String) -> String {
        let currentKey = lock.withLock { key }
        let authentication = HMAC<SHA256>.authenticationCode(
            for: Data(value.utf8),
            using: SymmetricKey(data: currentKey)
        )
        return authentication.map { String(format: "%02x", $0) }.joined()
    }

    private static func randomKey() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
