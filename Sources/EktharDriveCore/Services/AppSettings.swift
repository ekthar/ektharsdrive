import Foundation
import Network

public enum AppTheme: String, Codable, Sendable, CaseIterable {
    case system, light, dark
    public var label: String { rawValue.capitalized }
}

public struct AppSettings: Codable, Sendable, Equatable {
    public var launchAtLogin = false
    public var startMinimized = false
    public var notificationsEnabled = true
    public var theme: AppTheme = .system
    public var mountEngine: MountEngine = .automatic
    public var rclonePath: String?
    public var logLevel = "INFO"
    public var minFreeSpaceGB = 5
    public var autoReconnect = true
    public var setupCompleted = false
    public var googleClientID: String?

    public init() {}

    public var globals: MountGlobals { MountGlobals(logLevel: logLevel, minFreeSpaceBytes: Int64(minFreeSpaceGB) * .gibibyte) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        startMinimized = try c.decodeIfPresent(Bool.self, forKey: .startMinimized) ?? d.startMinimized
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? d.notificationsEnabled
        theme = try c.decodeIfPresent(AppTheme.self, forKey: .theme) ?? d.theme
        mountEngine = try c.decodeIfPresent(MountEngine.self, forKey: .mountEngine) ?? d.mountEngine
        rclonePath = try c.decodeIfPresent(String.self, forKey: .rclonePath)
        logLevel = try c.decodeIfPresent(String.self, forKey: .logLevel) ?? d.logLevel
        minFreeSpaceGB = try c.decodeIfPresent(Int.self, forKey: .minFreeSpaceGB) ?? d.minFreeSpaceGB
        autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? d.autoReconnect
        setupCompleted = try c.decodeIfPresent(Bool.self, forKey: .setupCompleted) ?? d.setupCompleted
        googleClientID = try c.decodeIfPresent(String.self, forKey: .googleClientID)
    }
}

/// Posts user notifications. The app supplies a UserNotifications implementation; tests use a recorder.
public protocol Notifier: Sendable {
    func notify(title: String, body: String)
}

public struct NullNotifier: Notifier {
    public init() {}
    public func notify(title: String, body: String) {}
}

/// Reports network reachability changes (NWPathMonitor). No polling.
public final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.ekthar.drive.network")
    public private(set) var isOnline = true

    public init() {}

    public func start(onChange: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            guard let self, online != self.isOnline else { return }
            self.isOnline = online
            onChange(online)
        }
        monitor.start(queue: queue)
    }

    public func stop() { monitor.cancel() }
}
