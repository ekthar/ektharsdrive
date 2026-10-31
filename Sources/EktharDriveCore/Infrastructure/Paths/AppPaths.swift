import Foundation

/// All on-disk locations the app owns. Directories holding sockets, config or keys are created 0700.
public struct AppPaths: Sendable {
    public let supportDirectory: URL
    public let cacheRoot: URL
    public let logsDirectory: URL

    public init(supportDirectory: URL, cacheRoot: URL, logsDirectory: URL) {
        self.supportDirectory = supportDirectory
        self.cacheRoot = cacheRoot
        self.logsDirectory = logsDirectory
    }

    public static func standard(fileManager: FileManager = .default) -> AppPaths {
        let lib = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return AppPaths(
            supportDirectory: lib.appendingPathComponent("Application Support/EktharDrive"),
            cacheRoot: lib.appendingPathComponent("Caches/EktharDrive"),
            logsDirectory: lib.appendingPathComponent("Logs/EktharDrive"))
    }

    public var databaseURL: URL { supportDirectory.appendingPathComponent("ekthar-drive.sqlite") }
    public var rcloneConfigURL: URL { supportDirectory.appendingPathComponent("rclone.conf") }
    public var knownHostsURL: URL { supportDirectory.appendingPathComponent("known_hosts") }
    public var runDirectory: URL { supportDirectory.appendingPathComponent("run") }
    public var binDirectory: URL { supportDirectory.appendingPathComponent("bin") }
    public var lockFileURL: URL { runDirectory.appendingPathComponent("app.lock") }

    public func cacheDirectory(for driveID: String) -> URL { cacheRoot.appendingPathComponent(driveID) }
    public func rcSocket(for driveID: String) -> URL { runDirectory.appendingPathComponent("\(driveID).sock") }
    public func pidFile(for driveID: String) -> URL { runDirectory.appendingPathComponent("\(driveID).pid") }
    public func logFile(for driveID: String) -> URL { logsDirectory.appendingPathComponent("\(driveID).log") }

    /// Creates every directory with owner-only permissions where it matters.
    public func prepare(fileManager: FileManager = .default) throws {
        for (dir, privateDir) in [(supportDirectory, true), (runDirectory, true), (binDirectory, false), (cacheRoot, true), (logsDirectory, true)] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            if privateDir { try FilePermissions.set(dir.path, mode: 0o700) }
        }
    }
}

public enum FilePermissions {
    public static func set(_ path: String, mode: mode_t) throws(DriveError) {
        guard chmod(path, mode) == 0 else {
            throw DriveError.permissionDenied("Could not set permissions on \(path): \(String(cString: strerror(errno)))")
        }
    }

    public static func mode(of path: String) -> mode_t? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return st.st_mode & 0o777
    }

    /// True if group/other have no access.
    public static func isOwnerOnly(_ path: String) -> Bool {
        guard let m = mode(of: path) else { return false }
        return m & 0o077 == 0
    }
}
