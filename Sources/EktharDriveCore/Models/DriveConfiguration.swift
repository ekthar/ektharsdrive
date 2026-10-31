import Foundation

/// The storage backend a drive talks to.
public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    case googleDrive = "google_drive"
    case oracleSFTP = "oracle_sftp"
    /// Encrypted folder inside Google Drive (rclone `crypt`). Names and contents are encrypted on this Mac.
    case vault = "vault"

    public var displayName: String {
        switch self {
        case .googleDrive: "Google Drive"
        case .oracleSFTP: "Oracle Drive"
        case .vault: "Vault"
        }
    }

    /// rclone backend type used in rclone.conf.
    public var rcloneBackend: String {
        switch self {
        case .googleDrive: "drive"
        case .oracleSFTP: "sftp"
        case .vault: "crypt"
        }
    }

    /// Whether the backend supports change polling (`--poll-interval`). crypt passes Google's changes through.
    public var supportsChangePolling: Bool { self == .googleDrive || self == .vault }
}

/// Which kernel/filesystem path is used to expose the volume to Finder.
public enum MountEngine: String, Codable, Sendable, CaseIterable {
    /// Pick macFUSE when it is installed and rclone was built with cmount; otherwise NFS.
    case automatic
    /// `rclone mount` through macFUSE.
    case macFUSE = "macfuse"
    /// `rclone nfsmount`: rclone serves NFS on 127.0.0.1 and macOS mounts it. No kernel extension required.
    case nfs

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .macFUSE: "macFUSE"
        case .nfs: "Built-in NFS"
        }
    }
}

/// Cache policy for one drive. rclone's VFS cache is the content cache; these are its limits.
public struct CachePolicy: Codable, Sendable, Equatable {
    public var maxSizeBytes: Int64
    public var maxAgeHours: Int
    public var bufferSizeMB: Int
    public var writeBackSeconds: Int
    public var dirCacheMinutes: Int

    public init(maxSizeBytes: Int64, maxAgeHours: Int = 168, bufferSizeMB: Int, writeBackSeconds: Int = 5, dirCacheMinutes: Int = 5) {
        self.maxSizeBytes = maxSizeBytes
        self.maxAgeHours = maxAgeHours
        self.bufferSizeMB = bufferSizeMB
        self.writeBackSeconds = writeBackSeconds
        self.dirCacheMinutes = dirCacheMinutes
    }

    /// Google reports changes every minute (`--poll-interval`), so folder listings can be kept a long time.
    public static let googleDefault = CachePolicy(maxSizeBytes: 8 * .gibibyte, bufferSizeMB: 32, dirCacheMinutes: 1440)
    public static let oracleDefault = CachePolicy(maxSizeBytes: 4 * .gibibyte, bufferSizeMB: 16)
}

/// Persisted configuration of one independent drive / Finder volume.
public struct DriveConfiguration: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var provider: ProviderKind
    public var remoteName: String
    public var remotePath: String
    /// Explicit mount path. `nil` means "use the engine default" (see `MountPathResolver`).
    public var mountPath: String?
    public var enabled: Bool
    public var autoMount: Bool
    public var cache: CachePolicy
    public var connectionTimeoutSeconds: Int
    public var maxRetryAttempts: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, name: String, provider: ProviderKind, remoteName: String, remotePath: String,
                mountPath: String? = nil, enabled: Bool = true, autoMount: Bool = false, cache: CachePolicy,
                connectionTimeoutSeconds: Int = 15, maxRetryAttempts: Int = 5,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.provider = provider
        self.remoteName = remoteName
        self.remotePath = remotePath
        self.mountPath = mountPath
        self.enabled = enabled
        self.autoMount = autoMount
        self.cache = cache
        self.connectionTimeoutSeconds = connectionTimeoutSeconds
        self.maxRetryAttempts = maxRetryAttempts
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The rclone remote spec, e.g. `gdrive:` or `oracle:/srv/ekthar-drive/files`.
    public var remoteSpec: String { "\(remoteName):\(remotePath)" }

    public static let googleDefault = DriveConfiguration(
        id: "google", name: "Google Drive", provider: .googleDrive, remoteName: "gdrive", remotePath: "",
        cache: .googleDefault)

    /// Created only when the user sets up a vault; never added automatically.
    public static let vaultDefault = DriveConfiguration(
        id: "vault", name: "Vault", provider: .vault, remoteName: "vault", remotePath: "",
        cache: CachePolicy(maxSizeBytes: 4 * .gibibyte, bufferSizeMB: 16, dirCacheMinutes: 1440))

    public static let oracleDefault = DriveConfiguration(
        id: "oracle", name: "Oracle Drive", provider: .oracleSFTP, remoteName: "oracle",
        remotePath: "/srv/ekthar-drive/files", cache: .oracleDefault)

    /// Validates fields that end up as rclone arguments or filesystem paths.
    public func validate() throws(DriveError) {
        func fail(_ reason: String) -> DriveError { .invalidConfiguration(reason) }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw fail("Drive name is empty.") }
        guard name.count <= 64 else { throw fail("Drive name is longer than 64 characters.") }
        guard !name.contains("/"), !name.contains(":"), !name.hasPrefix(".") else {
            throw fail("Drive name cannot contain '/' or ':' or start with '.'.")
        }
        let remoteNameOK = remoteName.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.\- ]{0,62}$"#, options: .regularExpression) != nil
        guard remoteNameOK, !remoteName.hasSuffix(" ") else { throw fail("Remote name '\(remoteName)' is not a valid rclone remote name.") }
        guard !remotePath.contains("\0"), !remotePath.contains("\n") else { throw fail("Remote path contains control characters.") }
        if provider == .oracleSFTP, !remotePath.isEmpty, !remotePath.hasPrefix("/") {
            throw fail("Oracle remote directory must be an absolute path.")
        }
        if remotePath.split(separator: "/").contains("..") { throw fail("Remote path must not contain '..'.") }
        if let mountPath {
            guard mountPath.hasPrefix("/") else { throw fail("Mount path must be absolute.") }
            guard !mountPath.split(separator: "/").contains("..") else { throw fail("Mount path must not contain '..'.") }
            let forbidden = ["/", "/System", "/Users", "/Applications", "/Library", "/Volumes", "/private", "/usr", "/bin", "/sbin", "/etc"]
            let normalized = mountPath.count > 1 && mountPath.hasSuffix("/") ? String(mountPath.dropLast()) : mountPath
            guard !forbidden.contains(normalized) else { throw fail("Mount path '\(mountPath)' is a system directory.") }
            guard normalized != FileManager.default.homeDirectoryForCurrentUser.path else { throw fail("Mount path cannot be your home folder.") }
        }
        guard cache.maxSizeBytes >= 256 * .mebibyte else { throw fail("Cache limit must be at least 256 MB.") }
        guard cache.maxSizeBytes <= 2048 * .gibibyte else { throw fail("Cache limit must be at most 2 TB.") }
        guard (1...8760).contains(cache.maxAgeHours) else { throw fail("Cache age must be between 1 and 8760 hours.") }
        guard (0...1024).contains(cache.bufferSizeMB) else { throw fail("Buffer size must be between 0 and 1024 MB.") }
        guard (0...3600).contains(cache.writeBackSeconds) else { throw fail("Write-back delay must be between 0 and 3600 seconds.") }
        guard (1...1440).contains(cache.dirCacheMinutes) else { throw fail("Directory cache time must be between 1 and 1440 minutes.") }
        guard (1...300).contains(connectionTimeoutSeconds) else { throw fail("Connection timeout must be between 1 and 300 seconds.") }
        guard (0...20).contains(maxRetryAttempts) else { throw fail("Retry attempts must be between 0 and 20.") }
    }
}

public extension Int64 {
    static let kibibyte: Int64 = 1024
    static let mebibyte: Int64 = 1024 * 1024
    static let gibibyte: Int64 = 1024 * 1024 * 1024
}

/// Oracle/SFTP connection details. Secrets (key passphrase) are NOT stored here; see `SecretStore`.
public struct SFTPConnection: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int
    public var username: String
    /// Path to the private key file on this Mac. The key itself is never copied or logged.
    public var privateKeyPath: String
    public var keyHasPassphrase: Bool

    public init(host: String, port: Int = 22, username: String, privateKeyPath: String, keyHasPassphrase: Bool = false) {
        self.host = host
        self.port = port
        self.username = username
        self.privateKeyPath = privateKeyPath
        self.keyHasPassphrase = keyHasPassphrase
    }

    public func validate() throws(DriveError) {
        func fail(_ reason: String) -> DriveError { .invalidConfiguration(reason) }
        let hostOK = host.range(of: #"^[A-Za-z0-9]([A-Za-z0-9.\-]{0,251}[A-Za-z0-9])?$"#, options: .regularExpression) != nil
            || host.range(of: #"^[0-9a-fA-F:]+$"#, options: .regularExpression) != nil && host.contains(":")
        guard hostOK else { throw fail("'\(host)' is not a valid host name or IP address.") }
        guard (1...65535).contains(port) else { throw fail("Port must be between 1 and 65535.") }
        guard username.range(of: #"^[a-z_][a-z0-9_.\-]{0,31}$"#, options: .regularExpression) != nil else {
            throw fail("'\(username)' is not a valid Unix user name.")
        }
        guard username != "root" else { throw fail("Do not connect as root. Create a dedicated SFTP user (see the Oracle setup guide).") }
        guard privateKeyPath.hasPrefix("/") else { throw fail("Private key path must be absolute.") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: privateKeyPath, isDirectory: &isDir), !isDir.boolValue else {
            throw fail("Private key not found at \(privateKeyPath).")
        }
    }
}
