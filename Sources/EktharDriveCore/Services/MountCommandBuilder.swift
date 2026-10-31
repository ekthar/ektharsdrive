import Foundation

public struct MountGlobals: Sendable, Equatable {
    public var logLevel: String
    public var minFreeSpaceBytes: Int64
    /// macFUSE 5 can run on Apple's FSKit instead of a kernel extension. On macOS 26+ the kernel backend
    /// needs Reduced Security on Apple Silicon, so FSKit is the default there.
    public var macFUSEUsesFSKit: Bool

    public init(logLevel: String = "INFO", minFreeSpaceBytes: Int64 = 5 * .gibibyte,
                macFUSEUsesFSKit: Bool = MountGlobals.fskitPreferred) {
        self.logLevel = logLevel
        self.minFreeSpaceBytes = minFreeSpaceBytes
        self.macFUSEUsesFSKit = macFUSEUsesFSKit
    }

    public static var fskitPreferred: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    }

    public static let allowedLogLevels = ["DEBUG", "INFO", "NOTICE", "ERROR"]
}

/// Default mount locations. macFUSE creates mount points under /Volumes itself; the NFS engine
/// cannot (only root can write /Volumes), so NFS volumes live in ~/Volumes.
public enum MountPathResolver {
    public static func path(for drive: DriveConfiguration, engine: MountEngine, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        if let explicit = drive.mountPath, !explicit.isEmpty { return explicit }
        switch engine {
        case .macFUSE, .automatic: return "/Volumes/\(drive.name)"
        case .nfs: return home.appendingPathComponent("Volumes").appendingPathComponent(drive.name).path
        }
    }
}

/// Builds the rclone argv for a mount. Pure function: every flag here was validated against rclone 1.75 `mount --help`.
/// Secrets never appear in arguments (the config password travels via environment).
public enum MountCommandBuilder {
    public static func arguments(drive: DriveConfiguration, engine: MountEngine, mountPath: String, cacheDirectory: String,
                                 rcSocket: String, configPath: String, globals: MountGlobals) throws(DriveError) -> [String] {
        try drive.validate()
        guard MountGlobals.allowedLogLevels.contains(globals.logLevel) else {
            throw .invalidConfiguration("Unsupported log level \(globals.logLevel).")
        }
        let subcommand: String
        switch engine {
        case .macFUSE: subcommand = "mount"
        case .nfs: subcommand = "nfsmount"
        case .automatic: throw .invalidConfiguration("Mount engine must be resolved before building arguments.")
        }
        let c = drive.cache
        var args: [String] = [
            subcommand, drive.remoteSpec, mountPath,
            "--config", configPath,
            "--volname", drive.name,
            "--cache-dir", cacheDirectory,
            "--vfs-cache-mode", "full",
            "--vfs-cache-max-size", ByteFormat.rcloneSize(c.maxSizeBytes),
            "--vfs-cache-max-age", "\(c.maxAgeHours)h",
            "--vfs-cache-min-free-space", ByteFormat.rcloneSize(globals.minFreeSpaceBytes),
            "--buffer-size", "\(c.bufferSizeMB)M",
            "--dir-cache-time", "\(c.dirCacheMinutes)m",
            "--vfs-write-back", "\(c.writeBackSeconds)s",
            "--contimeout", "\(drive.connectionTimeoutSeconds)s",
            "--rc", "--rc-addr", "unix://" + rcSocket, "--rc-no-auth",
            "--use-json-log", "--log-level", globals.logLevel,
            "--stats", "0",
        ]
        if drive.provider.supportsChangePolling { args += ["--poll-interval", "1m"] }
        if engine == .macFUSE {
            args += ["--noappledouble"]
            if globals.macFUSEUsesFSKit { args += ["-o", "backend=fskit"] }
        }
        return args
    }
}
