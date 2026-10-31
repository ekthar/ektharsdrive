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
    /// For `.nfs`, rclone only SERVES NFS on `127.0.0.1:nfsPort`; the app mounts it with `mount_nfs`
    /// (see `nfsMountArguments`) so it can choose options rclone's own `nfsmount` does not expose.
    public static func arguments(drive: DriveConfiguration, engine: MountEngine, mountPath: String, cacheDirectory: String,
                                 rcSocket: String, configPath: String, globals: MountGlobals, nfsPort: Int? = nil) throws(DriveError) -> [String] {
        try drive.validate()
        guard MountGlobals.allowedLogLevels.contains(globals.logLevel) else {
            throw .invalidConfiguration("Unsupported log level \(globals.logLevel).")
        }
        let c = drive.cache
        var args: [String]
        switch engine {
        case .macFUSE:
            args = ["mount", drive.remoteSpec, mountPath, "--volname", drive.name, "--attr-timeout", "5s"]
        case .nfs:
            guard let nfsPort, (1024...65535).contains(nfsPort) else { throw .invalidConfiguration("No local port for the NFS server.") }
            args = ["serve", "nfs", drive.remoteSpec, "--addr", "127.0.0.1:\(nfsPort)"]
        case .automatic:
            throw .invalidConfiguration("Mount engine must be resolved before building arguments.")
        }
        args += [
            "--config", configPath,
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
            // Open fast: fetch the first 8 MB of a file, then double the chunk up to 256 MB while reading on.
            // Finder previews and quick peeks then cost a few MB instead of 128 MB (rclone's default).
            "--vfs-read-chunk-size", "8M",
            "--vfs-read-chunk-size-limit", "256M",
        ]
        if drive.provider.supportsChangePolling { args += ["--poll-interval", "1m"] }
        if engine == .nfs {
            // Keep NFS file handles on disk so Finder windows stay valid across rclone restarts
            // instead of showing "stale" errors.
            args += ["--nfs-cache-type", "disk", "--nfs-cache-dir", cacheDirectory + "/nfs-handles"]
        }
        if engine == .macFUSE {
            args += ["--noappledouble"]
            if globals.macFUSEUsesFSKit { args += ["-o", "backend=fskit"] }
        }
        return args
    }

    /// `mount_nfs` options for the local rclone NFS server.
    /// - `locallocks`: file locks are kept by macOS. rclone's server has no lock service, so without this every
    ///   lock fails with ENOLCK and sandboxed apps (Preview, TextEdit, Pages) report "you don't have permission".
    /// - `nfc`: Unicode file names match what Finder expects.
    /// - `rsize/wsize 1 MB`, `readahead=16`: far fewer round trips for large files.
    /// - `intr`: a stuck read can be interrupted instead of hanging the app.
    public static func nfsMountOptions(port: Int) -> String {
        "port=\(port),mountport=\(port),tcp,vers=3,locallocks,nfc,intr,rsize=1048576,wsize=1048576,readahead=16"
    }

    public static func nfsMountArguments(port: Int, mountPath: String) -> [String] {
        ["-o", nfsMountOptions(port: port), "localhost:/", mountPath]
    }

    /// A free TCP port on 127.0.0.1 (asks the kernel, then releases it for rclone).
    public static func freeLocalPort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { return nil }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &out) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        guard got == 0 else { return nil }
        return Int(UInt16(bigEndian: out.sin_port))
    }
}
