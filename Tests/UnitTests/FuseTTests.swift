import Foundation
import Testing
@testable import EktharDriveCore

@Suite struct FuseTTests {
    let rclone = RcloneBinary(url: URL(fileURLWithPath: "/x/rclone"), version: "v1.75.2", supportsFUSEMount: true, supportsNFSMount: true)

    func report(fuseT: Bool, macFUSE: Bool = false, cmount: Bool = true) -> DependencyReport {
        var b = rclone
        b.supportsFUSEMount = cmount
        var r = DependencyReport(rclone: b, macFUSEVersion: macFUSE ? "5.5.0" : nil, libfuseInstalled: macFUSE,
                                 nfsClientAvailable: true, checkedAt: Date())
        r.fuseTInstalled = fuseT
        return r
    }

    @Test func resolvesOnlyWhenInstalled() throws {
        #expect(try report(fuseT: true).resolve(.fuseT) == .fuseT)
        #expect(throws: DriveError.self) { try report(fuseT: false).resolve(.fuseT) }
        #expect(throws: DriveError.self) { try report(fuseT: true, cmount: false).resolve(.fuseT) }
        // Automatic never picks FUSE-T on its own.
        #expect(try report(fuseT: true).resolve(.automatic) == .nfs)
    }

    @Test func picksFuseTLibraryThroughEnvironment() {
        #expect(DependencyChecker.environment(for: .fuseT) == ["CGOFUSE_LIBFUSE_PATH": "/usr/local/lib/libfuse-t.dylib"])
        #expect(DependencyChecker.environment(for: .macFUSE).isEmpty)
        #expect(DependencyChecker.environment(for: .nfs).isEmpty)
    }

    @Test func usesRcloneMountWithoutMacFUSEOnlyOptions() throws {
        let a = try MountCommandBuilder.arguments(drive: .googleDefault, engine: .fuseT, mountPath: "/Users/t/Volumes/Google Drive",
                                                  cacheDirectory: "/c", rcSocket: "/s", configPath: "/k",
                                                  globals: MountGlobals(macFUSEUsesFSKit: true), nfsPort: nil)
        #expect(Array(a.prefix(3)) == ["mount", "gdrive:", "/Users/t/Volumes/Google Drive"])
        #expect(!a.contains("backend=fskit"))
        #expect(!a.contains("--nfs-cache-type"))
    }

    @Test func detectsEngineFromMountTable() {
        #expect(DriveManager.engine(fsType: "macfuse", source: "gdrive{79NVJ}:") == .macFUSE)
        #expect(DriveManager.engine(fsType: "nfs", source: "localhost:/") == .nfs)
        #expect(DriveManager.engine(fsType: "nfs", source: "fuse-t:/gdrive") == .fuseT)
    }

    @Test func oldSettingsStillDecode() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"mountEngine":"macfuse"}"#.utf8))
        #expect(s.mountEngine == .macFUSE)
        let t = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"mountEngine":"fuset"}"#.utf8))
        #expect(t.mountEngine == .fuseT)
    }
}
