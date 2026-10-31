import Foundation
import Security

public enum SecretKey: String, Sendable, CaseIterable {
    /// Password that encrypts the app's rclone.conf (which holds the Google OAuth token).
    case rcloneConfigPassword = "rclone-config-password"
    case googleClientSecret = "google-client-secret"
    case oracleKeyPassphrase = "oracle-key-passphrase"
}

public protocol SecretStore: Sendable {
    func set(_ value: String, for key: SecretKey) throws(DriveError)
    func get(_ key: SecretKey) throws(DriveError) -> String?
    func delete(_ key: SecretKey) throws(DriveError)
}

/// Generic-password items in the user's login keychain, accessible only after first unlock on this device.
public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String = "com.ekthar.drive") { self.service = service }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func setRaw(_ value: String, account: String) throws(DriveError) {
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "Ekthar Drive"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw .permissionDenied("Keychain write failed (\(Self.message(status))).") }
    }

    public func getRaw(account: String) throws(DriveError) -> String? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw .permissionDenied("Keychain read failed (\(Self.message(status))). If macOS asked for your password, click Always Allow.")
        }
        return String(data: data, encoding: .utf8)
    }

    public func deleteRaw(account: String) throws(DriveError) {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw .permissionDenied("Keychain delete failed (\(Self.message(status))).")
        }
    }

    public func set(_ value: String, for key: SecretKey) throws(DriveError) { try setRaw(value, account: key.rawValue) }
    public func get(_ key: SecretKey) throws(DriveError) -> String? { try getRaw(account: key.rawValue) }
    public func delete(_ key: SecretKey) throws(DriveError) { try deleteRaw(account: key.rawValue) }

    static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }

    /// 32 random bytes from the system CSPRNG, base64url encoded.
    public static func randomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// All secrets in ONE Keychain item (a small JSON dictionary). macOS asks permission per item, so
/// separate items meant one password prompt per secret on every new build. Old separate items are
/// migrated on first use and then removed.
public final class BundledKeychainStore: SecretStore, @unchecked Sendable {
    private let keychain: KeychainStore
    private let bundleAccount = "secrets-v1"
    private let state = Locked<[String: String]?>(nil)

    public init(service: String = "com.ekthar.drive") { keychain = KeychainStore(service: service) }

    private func load() throws(DriveError) -> [String: String] {
        if let s = state.current { return s }
        var dict: [String: String] = [:]
        if let json = try keychain.getRaw(account: bundleAccount),
           let decoded = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)) {
            dict = decoded
        } else {
            // One-time migration from the old one-item-per-secret layout.
            for key in SecretKey.allCases {
                if let v = try? keychain.get(key) { dict[key.rawValue] = v }
            }
            if !dict.isEmpty { try save(dict) }
            for key in SecretKey.allCases { try? keychain.delete(key) }
        }
        state.withLock { $0 = dict }
        return dict
    }

    private func save(_ dict: [String: String]) throws(DriveError) {
        let data = (try? JSONEncoder().encode(dict)) ?? Data("{}".utf8)
        try keychain.setRaw(String(decoding: data, as: UTF8.self), account: bundleAccount)
        state.withLock { $0 = dict }
    }

    public func get(_ key: SecretKey) throws(DriveError) -> String? { try load()[key.rawValue] }

    public func set(_ value: String, for key: SecretKey) throws(DriveError) {
        var d = try load(); d[key.rawValue] = value; try save(d)
    }

    public func delete(_ key: SecretKey) throws(DriveError) {
        var d = try load(); d[key.rawValue] = nil; try save(d)
    }
}

/// Wraps the Keychain and remembers values for the life of the app, so the Keychain is asked at most once
/// per secret per launch. Each Keychain read can show a macOS permission prompt and BLOCKS until the user
/// answers; doing that on every rclone call (and on the main thread) froze the app.
public final class CachingSecretStore: SecretStore, @unchecked Sendable {
    private let base: SecretStore
    private let cache = Locked<[SecretKey: String?]>([:])

    public init(base: SecretStore) { self.base = base }

    public func get(_ key: SecretKey) throws(DriveError) -> String? {
        if let hit = cache.current[key] { return hit }
        let value = try base.get(key)
        cache.withLock { $0[key] = .some(value) }
        return value
    }

    public func set(_ value: String, for key: SecretKey) throws(DriveError) {
        try base.set(value, for: key)
        cache.withLock { $0[key] = .some(value) }
    }

    public func delete(_ key: SecretKey) throws(DriveError) {
        try base.delete(key)
        cache.withLock { $0[key] = .some(nil) }
    }

    /// Reads every secret on a background thread so a Keychain prompt never blocks the UI.
    public func warmUp() async {
        await Task.detached(priority: .userInitiated) { [self] in
            for key in SecretKey.allCases { _ = try? self.get(key) }
        }.value
    }
}

/// In-memory store for tests and previews. Never used by the shipping app.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let values = Locked<[SecretKey: String]>([:])
    public init() {}
    public func set(_ value: String, for key: SecretKey) throws(DriveError) { values.withLock { $0[key] = value } }
    public func get(_ key: SecretKey) throws(DriveError) -> String? { values.current[key] }
    public func delete(_ key: SecretKey) throws(DriveError) { values.withLock { $0[key] = nil } }
}
