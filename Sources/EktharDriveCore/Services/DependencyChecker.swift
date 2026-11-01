import Foundation

public struct DependencyReport: Sendable, Equatable {
    public var rclone: RcloneBinary?
    public var macFUSEVersion: String?
    public var libfuseInstalled: Bool
    public var nfsClientAvailable: Bool
    public var checkedAt: Date
    /// FUSE-T's library is present (/usr/local/lib/libfuse-t.dylib).
    public var fuseTInstalled: Bool = false
    public var fuseTUsable: Bool { fuseTInstalled && (rclone?.supportsFUSEMount ?? false) }

    public var macFUSEUsable: Bool { macFUSEVersion != nil && libfuseInstalled && (rclone?.supportsFUSEMount ?? false) }
    public var nfsUsable: Bool { nfsClientAvailable && (rclone?.supportsNFSMount ?? false) }
    public var canMount: Bool { macFUSEUsable || nfsUsable }

    /// Resolves the engine to use. Throws a precise missing-dependency error otherwise.
    public func resolve(_ requested: MountEngine) throws(DriveError) -> MountEngine {
        guard let rclone else {
            throw .dependencyMissing(.rclone, detail: "Install rclone from Settings > Advanced (one click), or from rclone.org/downloads.")
        }
        switch requested {
        case .macFUSE:
            guard macFUSEVersion != nil, libfuseInstalled else {
                throw .dependencyMissing(.macFUSE, detail: "Install macFUSE from macfuse.github.io and approve it in System Settings > Privacy & Security, or choose the Built-in NFS engine.")
            }
            guard rclone.supportsFUSEMount else {
                throw .dependencyMissing(.rcloneMountSupport, detail: "rclone at \(rclone.url.path) was built without macFUSE support (Homebrew builds are). Install the official rclone binary from Settings > Advanced.")
            }
            return .macFUSE
        case .nfs:
            guard nfsUsable else {
                throw .dependencyMissing(.nfsClient, detail: "rclone \(rclone.version) is too old for nfsmount (needs 1.65 or newer).")
            }
            return .nfs
        case .fuseT:
            guard fuseTInstalled else {
                throw .dependencyMissing(.fuseT, detail: "Install FUSE-T from Settings > Advanced (Get FUSE-T), or choose the Built-in NFS engine.")
            }
            guard rclone.supportsFUSEMount else {
                throw .dependencyMissing(.rcloneMountSupport, detail: "rclone at \(rclone.url.path) was built without FUSE support. Install the official rclone binary from Settings > Advanced.")
            }
            return .fuseT
        case .automatic:
            if macFUSEUsable { return .macFUSE }
            if nfsUsable { return .nfs }
            throw .dependencyMissing(.rcloneMountSupport, detail: "No mount engine is available. Install the official rclone binary (1.65 or newer).")
        }
    }
}

public enum DependencyChecker {
    public static let macFUSEBundle = "/Library/Filesystems/macfuse.fs"
    public static let libfusePaths = ["/usr/local/lib/libfuse.2.dylib", "/usr/local/lib/libfuse.dylib", "/opt/homebrew/lib/libfuse.2.dylib"]
    /// rclone's FUSE layer (cgofuse) loads this when CGOFUSE_LIBFUSE_PATH points at it.
    public static let fuseTLibrary = "/usr/local/lib/libfuse-t.dylib"
    public static let fuseTDownload = URL(string: "https://github.com/macos-fuse-t/fuse-t/releases/latest")!

    public static func check(paths: AppPaths, configuredRclone: String?) async -> DependencyReport {
        let rclone = await RcloneService.locate(paths: paths, configured: configuredRclone)
        var r = DependencyReport(rclone: rclone, macFUSEVersion: macFUSEVersion(),
                                 libfuseInstalled: libfusePaths.contains { FileManager.default.fileExists(atPath: $0) },
                                 nfsClientAvailable: FileManager.default.isExecutableFile(atPath: "/sbin/mount_nfs"),
                                 checkedAt: Date())
        r.fuseTInstalled = FileManager.default.fileExists(atPath: fuseTLibrary)
        return r
    }

    /// Extra environment that makes rclone use FUSE-T instead of macFUSE (both can be installed).
    public static func environment(for engine: MountEngine) -> [String: String] {
        engine == .fuseT ? ["CGOFUSE_LIBFUSE_PATH": fuseTLibrary] : [:]
    }

    public static func macFUSEVersion() -> String? {
        let plist = URL(fileURLWithPath: macFUSEBundle).appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plist) else { return nil }
        return (dict["CFBundleShortVersionString"] as? String) ?? (dict["CFBundleVersion"] as? String) ?? "installed"
    }
}
