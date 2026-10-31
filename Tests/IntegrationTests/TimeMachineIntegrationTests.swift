import Foundation
import Testing
@testable import EktharDriveCore

// The Time Machine disk on a real rclone mount: created as a sparse bundle on the drive, opened as an
// external APFS disk, closed before the drive ejects, and its bands uploaded to the server.
extension SFTPMountIntegrationTests {

    @Test func timeMachineDiskOnRealMount() async throws {
        try await withHarness(name: "tm") { h in
            try await h.connect()
            await h.manager.mount("oracle")
            let mount = try #require(h.manager.state("oracle").mountPath)
            // Small size for the test; the app's own picker starts at 100 GB.
            try await TimeMachineDisk.create(mountPath: mount, sizeGB: 50)
            await h.manager.openTimeMachineDisk("oracle")
            let volume = try #require(TimeMachineDisk.attachedVolume, "disk image is open")
            #expect(h.manager.timeMachineDriveID == "oracle")

            // macOS sees an external APFS disk, which Time Machine accepts.
            let info = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/sbin/diskutil"), arguments: ["info", volume],
                                                     environment: SafeEnvironment.base(), stdin: nil, timeout: .seconds(30))
            #expect(info.stdout.contains("APFS"))
            #expect(info.stdout.contains("External"))

            // Write into it like a backup would.
            try writeRandom(URL(fileURLWithPath: volume).appendingPathComponent("backup.bin"), bytes: 8 << 20)

            // Ejecting the drive closes the disk first, waits for uploads, and the bands reach the server.
            await h.manager.unmount("oracle", waitForUploads: true)
            #expect(h.manager.state("oracle").phase == .unmounted)
            #expect(TimeMachineDisk.attachedVolume == nil)
            let bands = h.server.data.appendingPathComponent("files/\(TimeMachineDisk.bundleName)/bands")
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: bands.path)) ?? []).count > 0, "bands uploaded")

            // Mounting again reopens it automatically.
            await h.manager.mount("oracle")
            #expect(await eventually(.seconds(60)) { TimeMachineDisk.attachedVolume != nil })
            await h.manager.unmount("oracle", waitForUploads: true)
            #expect(TimeMachineDisk.attachedVolume == nil)
        }
    }
}
