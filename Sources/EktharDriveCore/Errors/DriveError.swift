import Foundation

public enum Dependency: String, Sendable, Codable {
    case rclone
    case rcloneMountSupport
    case macFUSE
    case nfsClient
}

/// Every failure the app can surface. Each case maps to a distinct UI state and recovery action.
public enum DriveError: Error, Sendable, Equatable, Codable {
    case dependencyMissing(Dependency, detail: String)
    case invalidConfiguration(String)
    case notConfigured
    case authenticationFailed(String)
    case hostKeyUnknown(host: String)
    case hostKeyMismatch(host: String)
    case networkUnavailable
    case remoteUnavailable(String)
    case mountPointOccupied(path: String, by: String)
    case mountPointBusy(path: String)
    case mountFailed(String)
    case processExited(code: Int32, detail: String)
    case pendingWrites(count: Int)
    case localDiskFull(freeBytes: Int64)
    case cacheFull
    case rcUnavailable(String)
    case timeout(String)
    case permissionDenied(String)
    case alreadyRunning
    case unknown(String)

    /// The coarse category the UI distinguishes (brief section 19).
    public var category: ErrorCategory {
        switch self {
        case .networkUnavailable: .disconnected
        case .authenticationFailed, .hostKeyMismatch, .hostKeyUnknown: .authentication
        case .mountPointOccupied, .mountPointBusy, .mountFailed, .dependencyMissing, .alreadyRunning: .mount
        case .remoteUnavailable, .timeout: .remoteStorage
        case .localDiskFull, .cacheFull: .localDisk
        case .pendingWrites: .pendingWrite
        case .processExited, .rcUnavailable, .unknown, .permissionDenied: .degraded
        case .invalidConfiguration, .notConfigured: .configuration
        }
    }

    /// Whether automatic retry with backoff makes sense. Security and configuration failures never auto-retry.
    public var isRetryable: Bool {
        switch self {
        case .networkUnavailable, .remoteUnavailable, .timeout, .processExited, .rcUnavailable, .unknown: true
        default: false
        }
    }

    public var title: String {
        switch self {
        case .dependencyMissing(let dep, _):
            switch dep {
            case .rclone: "rclone is not installed"
            case .rcloneMountSupport: "This rclone build cannot mount"
            case .macFUSE: "macFUSE is not installed"
            case .nfsClient: "The macOS NFS client is unavailable"
            }
        case .invalidConfiguration: "Invalid configuration"
        case .notConfigured: "Not configured"
        case .authenticationFailed: "Authentication failed"
        case .hostKeyUnknown: "Server identity not verified"
        case .hostKeyMismatch: "Server identity changed"
        case .networkUnavailable: "No network connection"
        case .remoteUnavailable: "Remote storage unavailable"
        case .mountPointOccupied: "Mount location is in use"
        case .mountPointBusy: "Volume is busy"
        case .mountFailed: "Mount failed"
        case .processExited: "Filesystem process stopped"
        case .pendingWrites(let n): "\(n) upload\(n == 1 ? "" : "s") still pending"
        case .localDiskFull: "Local disk is nearly full"
        case .cacheFull: "Cache is full"
        case .rcUnavailable: "Lost contact with the filesystem process"
        case .timeout: "Timed out"
        case .permissionDenied: "Permission denied"
        case .alreadyRunning: "Already mounted"
        case .unknown: "Unexpected error"
        }
    }

    public var detail: String {
        switch self {
        case .dependencyMissing(_, let d): d
        case .invalidConfiguration(let r): r
        case .notConfigured: "Connect this drive in Settings > Accounts before mounting it."
        case .authenticationFailed(let r): r
        case .hostKeyUnknown(let h): "The SSH host key for \(h) has not been verified. Verify the fingerprint before connecting."
        case .hostKeyMismatch(let h): "The SSH host key for \(h) no longer matches the one you trusted. This can mean the server was rebuilt, or that someone is intercepting the connection. Ekthar Drive will not connect until you verify the new key."
        case .networkUnavailable: "This Mac is offline. Ekthar Drive will reconnect when the network returns."
        case .remoteUnavailable(let r): r
        case .mountPointOccupied(let p, let by): "\(p) is already used by \(by)."
        case .mountPointBusy(let p): "Files on \(p) are open in another app. Close them and try again."
        case .mountFailed(let r): r
        case .processExited(let code, let d): "rclone exited with status \(code). \(d)"
        case .pendingWrites(let n): "\(n) file\(n == 1 ? " is" : "s are") still uploading. Unmounting now could lose data, so Ekthar Drive will wait for uploads to finish."
        case .localDiskFull(let free): "Only \(ByteFormat.string(free)) free on this Mac. Free up space or lower the cache limit."
        case .cacheFull: "The cache has no room for new data. Free local disk space or raise the cache limit."
        case .rcUnavailable(let r): r
        case .timeout(let r): r
        case .permissionDenied(let r): r
        case .alreadyRunning: "This drive is already mounted."
        case .unknown(let r): r
        }
    }
}

public enum ErrorCategory: String, Sendable {
    case disconnected, degraded, authentication, mount, remoteStorage, localDisk, pendingWrite, configuration
}

extension DriveError: LocalizedError {
    public var errorDescription: String? { "\(title): \(detail)" }
}
