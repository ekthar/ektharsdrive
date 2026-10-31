import Foundation
import Testing
@testable import EktharDriveCore

@Suite struct ReliabilityTests {
    @Test func probeAnswersForHealthyPathsAndTimesOut() async throws {
        #expect(await VolumeProbe.responds("/", within: 2))
        #expect(await VolumeProbe.responds("/definitely/not/here", within: 2) == false, "missing path is not healthy")
    }

    @Test func sleepGuardHoldsOnlyWhileUploading() {
        let g = UploadSleepGuard()
        #expect(!g.isHolding)
        g.update(pendingUploads: 3)
        #expect(g.isHolding)
        g.update(pendingUploads: 1)
        #expect(g.isHolding)
        g.update(pendingUploads: 0)
        #expect(!g.isHolding)
    }

    @Test func crashReportIsPrivateRedactedAndPruned() throws {
        let dir = try makeTempDir("crash")
        defer { try? FileManager.default.removeItem(at: dir) }
        var last: URL?
        for i in 0..<23 {
            last = CrashReporter.write(driveID: "google", driveName: "Google Drive", status: 2, error: .processExited(code: 2, detail: "x"),
                                       recentOutput: ["line \(i)", "token = {\"access_token\":\"ya29.SECRET\"}"],
                                       logsDirectory: dir, now: Date().addingTimeInterval(Double(i)))
        }
        let url = try #require(last)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("line 22") && text.contains("exit status: 2"))
        #expect(!text.contains("ya29.SECRET"), "redacted")
        #expect(FilePermissions.isOwnerOnly(url.path))
        let count = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("crash-") }.count
        #expect(count == 20, "keeps the newest 20")
    }

    @Test func googleMountsAreRateLimited() throws {
        let g = try MountCommandBuilder.arguments(drive: .googleDefault, engine: .nfs, mountPath: "/m", cacheDirectory: "/c",
                                                  rcSocket: "/s", configPath: "/k", globals: MountGlobals(), nfsPort: 47001)
        #expect(g.firstIndex(of: "--tpslimit").map { g[$0 + 1] } == "10")
        let o = try MountCommandBuilder.arguments(drive: .oracleDefault, engine: .nfs, mountPath: "/m", cacheDirectory: "/c",
                                                  rcSocket: "/s", configPath: "/k", globals: MountGlobals(), nfsPort: 47001)
        #expect(!o.contains("--tpslimit"), "SFTP has no API quota")
    }
}
