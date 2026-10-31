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

    private func baseQuery(_ key: SecretKey) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key.rawValue]
    }

    public func set(_ value: String, for key: SecretKey) throws(DriveError) {
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery(key) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "Ekthar Drive (\(key.rawValue))"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw .permissionDenied("Keychain write failed (\(Self.message(status))).") }
    }

    public func get(_ key: SecretKey) throws(DriveError) -> String? {
        var q = baseQuery(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw .permissionDenied("Keychain read failed (\(Self.message(status))).")
        }
        return String(data: data, encoding: .utf8)
    }

    public func delete(_ key: SecretKey) throws(DriveError) {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw .permissionDenied("Keychain delete failed (\(Self.message(status))).")
        }
    }

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

/// In-memory store for tests and previews. Never used by the shipping app.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let values = Locked<[SecretKey: String]>([:])
    public init() {}
    public func set(_ value: String, for key: SecretKey) throws(DriveError) { values.withLock { $0[key] = value } }
    public func get(_ key: SecretKey) throws(DriveError) -> String? { values.current[key] }
    public func delete(_ key: SecretKey) throws(DriveError) { values.withLock { $0[key] = nil } }
}
