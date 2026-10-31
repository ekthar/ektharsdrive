import Foundation

public enum TransferDirection: String, Sendable, Codable {
    case upload, download
}

/// Transfer states. rclone has no per-file pause, so `.paused` is never produced by the tracker;
/// it exists so the persisted schema matches the product spec.
public enum TransferStatus: String, Sendable, Codable, CaseIterable {
    case queued, running, paused, waiting, completed, failed, cancelled

    public var isTerminal: Bool { [.completed, .failed, .cancelled].contains(self) }
    public var label: String { rawValue.capitalized }
}

public struct Transfer: Sendable, Identifiable, Equatable, Codable {
    public var id: UUID
    public var driveID: String
    public var name: String
    public var sourcePath: String
    public var destinationPath: String
    public var direction: TransferDirection
    public var totalBytes: Int64?
    public var transferredBytes: Int64
    /// Bytes per second as reported by rclone.
    public var speed: Double?
    /// Seconds remaining as reported by rclone; only set when rclone computed one.
    public var eta: Double?
    public var status: TransferStatus
    public var startedAt: Date
    public var completedAt: Date?
    public var errorMessage: String?

    public init(id: UUID = UUID(), driveID: String, name: String, sourcePath: String, destinationPath: String,
                direction: TransferDirection, totalBytes: Int64?, transferredBytes: Int64 = 0, speed: Double? = nil,
                eta: Double? = nil, status: TransferStatus, startedAt: Date = Date(), completedAt: Date? = nil,
                errorMessage: String? = nil) {
        self.id = id
        self.driveID = driveID
        self.name = name
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.direction = direction
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.speed = speed
        self.eta = eta
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
    }

    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(transferredBytes) / Double(totalBytes))
    }
}

public enum Severity: String, Sendable, Codable, CaseIterable, Comparable {
    case info, warning, error
    private var rank: Int { switch self { case .info: 0; case .warning: 1; case .error: 2 } }
    public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
}

public struct ActivityEvent: Sendable, Identifiable, Equatable, Codable {
    public var id: Int64?
    public var driveID: String?
    public var eventType: String
    public var message: String
    public var severity: Severity
    public var timestamp: Date

    public init(id: Int64? = nil, driveID: String?, eventType: String, message: String, severity: Severity, timestamp: Date = Date()) {
        self.id = id
        self.driveID = driveID
        self.eventType = eventType
        self.message = message
        self.severity = severity
        self.timestamp = timestamp
    }
}
