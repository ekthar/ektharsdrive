import Foundation
import Testing
@testable import EktharDriveCore

// Upload queue controls on a real mount. A long write-back delay keeps files in rclone's queue,
// so pause, resume and "upload now" can be checked against what reaches the server.
extension SFTPMountIntegrationTests {

    @Test func pauseResumeAndUploadNowOnRealQueue() async throws {
        try await withHarness(writeBack: 40, name: "uq") { h in
            try await h.connect()
            await h.manager.mount("oracle")
            let mnt = URL(fileURLWithPath: h.mountPath)
            let onServer = { (name: String) in FileManager.default.fileExists(atPath: h.server.data.appendingPathComponent("files/\(name)").path) }
            try Data("first".utf8).write(to: mnt.appendingPathComponent("a.txt"))
            try Data("second".utf8).write(to: mnt.appendingPathComponent("b.txt"))

            // Both files show up as queued uploads with rclone's queue ids. (macOS may add "._" files too.)
            #expect(await eventually(.seconds(15)) {
                _ = await h.manager.pollOnce()
                return h.manager.allActiveTransfers.filter { $0.queueID != nil && ["a.txt", "b.txt"].contains($0.name) }.count == 2
            })
            let a = try #require(h.manager.allActiveTransfers.first { $0.name == "a.txt" })
            let b = try #require(h.manager.allActiveTransfers.first { $0.name == "b.txt" })

            // Pause a: rclone moves its start ~31 years ahead and the app shows Paused.
            await h.manager.pauseUpload(a)
            #expect(h.manager.allActiveTransfers.first { $0.name == "a.txt" }?.status == .paused)
            #expect(h.manager.hasHeldUploads("oracle"))

            // Upload b now, without waiting for the 40 s write-back.
            await h.manager.uploadNow(b)
            #expect(await eventually(.seconds(15)) { onServer("b.txt") }, "upload now skips the write-back delay")
            #expect(!onServer("a.txt"), "the paused file stays on the Mac")

            // rclone forgetting the pause (after a remount it re-queues with the normal delay) is undone on the next poll.
            let rc = RcClient(socketPath: h.paths.rcSocket(for: "oracle").path)
            let qa = try #require(try await UploadQueue.items(rc).first { $0.name == "a.txt" }?.id)
            try await UploadQueue.setStart(rc, id: qa, seconds: 40)
            _ = await h.manager.pollOnce()
            let expiry = try await UploadQueue.items(rc).first { $0.name == "a.txt" }?.expiry ?? 0
            #expect(expiry > UploadQueue.holdThreshold, "pause re-applied: starts in \(expiry) s")

            // Ejecting with "wait for uploads" starts paused uploads, so the wait can end.
            await h.manager.unmount("oracle", waitForUploads: true)
            #expect(h.manager.state("oracle").phase == .unmounted)
            #expect(onServer("a.txt"), "nothing is lost: the paused file uploaded before ejecting")
            #expect(!h.manager.hasHeldUploads("oracle"))
        }
    }
}
