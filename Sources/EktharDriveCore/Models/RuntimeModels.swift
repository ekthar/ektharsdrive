import Foundation

/// Lifecycle of one drive's filesystem process.
public enum MountPhase: Sendable, Equatable {
    case unmounted
    case mounting
    case mounted
    /// Unmount requested; waiting for `count` uploads to finish before unmounting.
    case waitingForUploads(count: Int)
    case unmounting
    /// Automatic retry scheduled.
    case retrying(attempt: Int, at: Date)
    /// Stopped after an error that needs user action (or retries were exhausted).
    case failed

    public var isActive: Bool {
        switch self {
        case .mounted, .waitingForUploads, .unmounting: true
        default: false
        }
    }

    public var label: String {
        switch self {
        case .unmounted: "Not mounted"
        case .mounting: "Mounting"
        case .mounted: "Mounted"
        case .waitingForUploads(let n): "Finishing \(n) upload\(n == 1 ? "" : "s")"
        case .unmounting: "Unmounting"
        case .retrying(let a, _): "Reconnecting (attempt \(a))"
        case .failed: "Stopped"
        }
    }
}

/// Whether the account / server credentials are set up and were last verified.
public enum ConnectionState: Sendable, Equatable {
    case notConfigured
    case unverified
    case testing
    case connected(at: Date)
    case failed(DriveError)

    public var isConfigured: Bool { self != .notConfigured }
}

/// Capacity numbers. `nil` means the provider did not report the value; the UI shows "Unavailable".
public struct StorageUsage: Sendable, Equatable, Codable {
    public var total: Int64?
    public var used: Int64?
    public var free: Int64?
    public var trashed: Int64?
    public var fetchedAt: Date

    public init(total: Int64?, used: Int64?, free: Int64?, trashed: Int64? = nil, fetchedAt: Date = Date()) {
        self.total = total
        self.used = used
        self.free = free
        self.trashed = trashed
        self.fetchedAt = fetchedAt
    }

    public var usedFraction: Double? {
        guard let total, total > 0, let used else { return nil }
        return min(1, max(0, Double(used) / Double(total)))
    }
}

/// Real measurements of a drive's rclone VFS cache.
public struct CacheStats: Sendable, Equatable {
    public var bytesUsed: Int64
    public var files: Int?
    public var uploadsInProgress: Int
    public var uploadsQueued: Int
    public var erroredFiles: Int
    public var outOfSpace: Bool
    public var source: Source
    public var measuredAt: Date

    public enum Source: String, Sendable { case liveProcess, diskScan }

    public init(bytesUsed: Int64, files: Int?, uploadsInProgress: Int = 0, uploadsQueued: Int = 0, erroredFiles: Int = 0,
                outOfSpace: Bool = false, source: Source, measuredAt: Date = Date()) {
        self.bytesUsed = bytesUsed
        self.files = files
        self.uploadsInProgress = uploadsInProgress
        self.uploadsQueued = uploadsQueued
        self.erroredFiles = erroredFiles
        self.outOfSpace = outOfSpace
        self.source = source
        self.measuredAt = measuredAt
    }

    public var pendingUploads: Int { uploadsInProgress + uploadsQueued }
}

public enum HealthLevel: Int, Sendable, Comparable {
    case inactive = 0, healthy, degraded, error
    public static func < (a: HealthLevel, b: HealthLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Everything the UI shows about one drive at runtime. Built only from real observations.
public struct DriveRuntime: Sendable, Equatable {
    public var phase: MountPhase = .unmounted
    public var connection: ConnectionState = .notConfigured
    public var lastError: DriveError?
    public var mountPath: String?
    public var engine: MountEngine?
    public var pid: Int32?
    public var usage: StorageUsage?
    public var cache: CacheStats?
    public var lastSuccessfulConnection: Date?
    public var accountLabel: String?
    public var retryAttempt: Int = 0

    public init() {}

    public var health: HealthLevel {
        if case .failed = phase { return .error }
        if case .failed = connection { return .error }
        if case .retrying = phase { return .degraded }
        if let cache, cache.erroredFiles > 0 || cache.outOfSpace { return .degraded }
        if lastError != nil, phase == .mounted { return .degraded }
        if phase == .mounted { return .healthy }
        if case .connected = connection { return .healthy }
        return .inactive
    }
}
