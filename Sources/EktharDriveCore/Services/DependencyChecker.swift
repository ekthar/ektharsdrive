import Foundation

public struct DependencyReport: Sendable, Equatable {
    public var rclone: RcloneBinary?
    public var macFUSEVersion: String?
    public var libfuseInstalled: Bool
    public var nfsClientAvailable: Bool
    public var checkedAt: Date

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

    public static func check(paths: AppPaths, configuredRclone: String?) async -> DependencyReport {
        let rclone = await RcloneService.locate(paths: paths, configured: configuredRclone)
        return DependencyReport(rclone: rclone, macFUSEVersion: macFUSEVersion(),
                                libfuseInstalled: libfusePaths.contains { FileManager.default.fileExists(atPath: $0) },
                                nfsClientAvailable: FileManager.default.isExecutableFile(atPath: "/sbin/mount_nfs"),
                                checkedAt: Date())
    }

    public static func macFUSEVersion() -> String? {
        let plist = URL(fileURLWithPath: macFUSEBundle).appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plist) else { return nil }
        return (dict["CFBundleShortVersionString"] as? String) ?? (dict["CFBundleVersion"] as? String) ?? "installed"
    }
}
