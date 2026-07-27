import CryptoKit
import Foundation
import LocalAuthentication
import Security

protocol HistoryIdentityProviding: Sendable {
    func applicationIdentity(bundleIdentifier: String?, fallbackIdentity: String) -> String
    func deviceIdentity(registryID: UInt64, bsdName: String) -> String
    func rotate() throws
}

protocol HistoryIdentityKeyStoring: Sendable {
    func loadKey() throws -> Data?
    func saveKey(_ key: Data) throws
    func deleteKey() throws
}

struct HistoryKeychainStore: HistoryIdentityKeyStoring {
    private let service = "com.jianyintang.FindDiskKiller.history-identity"
    private let account = "installation-key-v1"

    func loadKey() throws -> Data? {
        var query = noninteractiveQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError(status: status)
        }
        return data
    }

    func saveKey(_ key: Data) throws {
        var query = baseQuery
        query[kSecValueData as String] = key
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = [kSecValueData as String: key] as CFDictionary
            let updateStatus = SecItemUpdate(noninteractiveQuery as CFDictionary, update)
            guard updateStatus == errSecSuccess else { throw KeychainError(status: updateStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    func deleteKey() throws {
        let status = SecItemDelete(noninteractiveQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }

    private var noninteractiveQuery: [String: Any] {
        var query = baseQuery
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }
}

final class HistoryIdentityProvider: HistoryIdentityProviding, @unchecked Sendable {
    static let shared = HistoryIdentityProvider()

    private let lock = NSLock()
    private let keyStore: any HistoryIdentityKeyStoring
    private var key: Data

    init(keyStore: any HistoryIdentityKeyStoring = HistoryKeychainStore()) {
        self.keyStore = keyStore
        if let saved = try? keyStore.loadKey(), saved.count == 32 {
            key = saved
        } else {
            let generated = Self.randomKey()
            key = generated
            try? keyStore.saveKey(generated)
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
        let replacement = Self.randomKey()
        try keyStore.saveKey(replacement)
        lock.withLock { key = replacement }
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
        var data = Data(repeating: 0, count: 32)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        if status != errSecSuccess {
            return Data(SHA256.hash(data: Data(UUID().uuidString.utf8)))
        }
        return data
    }
}

private struct KeychainError: Error {
    let status: OSStatus
}
