import Foundation
import Testing
@testable import EktharDriveCore

@Suite struct UploadQueueTests {
    func item(_ name: String, id: Int64, expiry: Double, uploading: Bool = false, tries: Int = 0) -> RcVFSQueue.Item {
        RcVFSQueue.Item(name: name, id: id, size: 10, expiry: expiry, tries: tries, delay: 5, uploading: uploading)
    }

    @Test func trackerShowsQueueStates() {
        var t = TransferTracker(driveID: "g", remoteName: "gdrive")
        let u = t.update(transferring: [], completed: [], queue: [
            item("a.txt", id: 1, expiry: 3),
            item("b.txt", id: 2, expiry: UploadQueue.holdSeconds),
            item("c.txt", id: 3, expiry: 0, tries: 2),
            item("d.txt", id: 4, expiry: 0, uploading: true),
        ])
        let byName = Dictionary(uniqueKeysWithValues: u.active.map { ($0.name, $0) })
        #expect(byName["a.txt"]?.status == .queued)
        #expect(byName["a.txt"]?.queueID == 1)
        #expect(byName["a.txt"]?.startsIn == 3)
        #expect(byName["b.txt"]?.status == .paused)
        #expect(byName["b.txt"]?.errorMessage == nil)
        #expect(byName["c.txt"]?.status == .waiting)
        #expect(byName["d.txt"] == nil, "already sending: shown from core/stats, not the queue")
    }

    @Test func sendingTransferCarriesJobGroup() {
        var t = TransferTracker(driveID: "g", remoteName: "gdrive")
        let run = RcTransferring(name: "big.mov", bytes: 50, size: 100, speed: 1, speedAvg: 1, eta: 50, percentage: 50,
                                 srcFs: "gdrive:", dstFs: "oracle:/files", group: "job/7")
        let u = t.update(transferring: [run], completed: [], queue: [])
        #expect(u.active.first?.jobID == 7)
        var plain = u.active[0]
        plain.group = "global_stats"
        #expect(plain.jobID == nil)
    }

    @Test func reholdOnlyWhatRcloneForgot() {
        let items = [
            item("held-forgotten", id: 1, expiry: 5),
            item("held-ok", id: 2, expiry: UploadQueue.holdSeconds),
            item("held-sending", id: 3, expiry: 0, uploading: true),
            item("not-held", id: 4, expiry: 5),
        ]
        let fix = UploadQueue.needsHold(items, held: ["held-forgotten", "held-ok", "held-sending"])
        #expect(fix.map(\.name) == ["held-forgotten"])
    }

    @Test func heldRoundTrip() {
        let held: [String: Set<String>] = ["google": ["a", "b/c.txt"], "oracle": []]
        let back = UploadQueue.decodeHeld(UploadQueue.encodeHeld(held))
        #expect(back == ["google": ["a", "b/c.txt"]], "empty sets are dropped")
        #expect(UploadQueue.decodeHeld("nonsense").isEmpty)
    }
}

@Suite struct VaultTests {
    @Test func passwordRules() {
        #expect(VaultProvider.passwordProblem("short", confirm: "short") != nil)
        #expect(VaultProvider.passwordProblem("aaaaaaaaaaaaaa", confirm: "aaaaaaaaaaaaaa") != nil, "too repetitive")
        #expect(VaultProvider.passwordProblem("correct horse battery", confirm: "correct horse batterY") != nil)
        #expect(VaultProvider.passwordProblem("correct horse battery", confirm: "correct horse battery") == nil)
    }

    @Test func vaultDriveShape() throws {
        let v = DriveConfiguration.vaultDefault
        try v.validate()
        #expect(v.provider.rcloneBackend == "crypt")
        #expect(v.remoteSpec == "vault:")
        #expect(!v.autoMount)
        #expect(v.provider.supportsChangePolling)
    }

    @Test func vaultMountSharesGoogleBudget() throws {
        let a = try MountCommandBuilder.arguments(drive: .vaultDefault, engine: .nfs, mountPath: "/m", cacheDirectory: "/c",
                                                  rcSocket: "/s", configPath: "/k", globals: MountGlobals(), nfsPort: 47002)
        #expect(a.firstIndex(of: "--tpslimit").map { a[$0 + 1] } == "5")
        #expect(a.contains("--poll-interval"))
        #expect(!a.joined(separator: " ").localizedCaseInsensitiveContains("password"), "the key never goes in arguments")
    }

    @Test func oldSettingsGetDropZoneDefault() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(s.menuBarDropZone)
    }

    @Test func oldTransfersDecodeWithoutQueueFields() throws {
        let t = Transfer(driveID: "g", name: "x", sourcePath: "x", destinationPath: "gdrive:x", direction: .upload, totalBytes: 1, status: .completed)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as! [String: Any]
        json["queueID"] = nil; json["group"] = nil; json["startsIn"] = nil
        let back = try JSONDecoder().decode(Transfer.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back.queueID == nil && back.jobID == nil)
    }
}
