import Foundation
import Testing
@testable import EktharDriveCore

// The vault on a real rclone `crypt` remote. The base is the local SFTP test server instead of Google,
// so the same code path (create, encrypt, wrong password, reopen) runs without touching a real account.
extension SFTPMountIntegrationTests {

    @Test func vaultEncryptsAndRefusesWrongPassword() async throws {
        try await withHarness(name: "vt") { h in
            try await h.connect()
            let rclone = try #require(h.manager.rcloneService)
            let folder = h.server.data.appendingPathComponent("files/Ekthar Vault")
            let vault = VaultProvider(rclone: rclone, remoteName: "testvault", baseRemote: "oracle", folder: "/files/Ekthar Vault")
            let password = "correct horse battery staple"

            // New vault: the folder is created and the password saved in the (test) Keychain.
            try await vault.configure(password: password)
            #expect(FileManager.default.fileExists(atPath: folder.path))
            #expect(vault.hasSavedPassword())

            // Write a file through the vault.
            let local = h.root.appendingPathComponent("secret plan.txt")
            try Data("top secret contents".utf8).write(to: local)
            let env = try await rclone.environment(extra: try await vault.runtimeEnvironment())
            let put = try await rclone.run(["copyto", local.path, "testvault:Plans/secret plan.txt"], environment: env)
            #expect(put.exitCode == 0, "\(put.combinedLines.suffix(3))")

            // On the server, names and contents are scrambled.
            let stored = (FileManager.default.enumerator(atPath: folder.path)?.allObjects as? [String]) ?? []
            #expect(stored.count == 2, "one folder, one file: \(stored)")
            #expect(!stored.contains { $0.contains("Plans") || $0.contains("secret") }, "names are encrypted: \(stored)")
            for name in stored {
                let data = (try? Data(contentsOf: folder.appendingPathComponent(name))) ?? Data()
                #expect(data.range(of: Data("top secret".utf8)) == nil, "contents are encrypted")
            }

            // The config on disk never holds the password.
            let dump = try await rclone.run(["config", "show", "testvault"])
            #expect(!dump.stdout.contains("password"), "no password in rclone.conf")

            // A wrong password is refused and leaves nothing behind.
            await #expect(throws: DriveError.self) { try await vault.configure(password: "wrong password 123") }
            #expect(!(await rclone.remoteExists("testvault")))
            #expect((FileManager.default.enumerator(atPath: folder.path)?.allObjects.count ?? 0) == 2, "encrypted files untouched")

            // The right password opens the same files again, as on a new Mac.
            try await vault.configure(password: password)
            let back = try await rclone.run(["cat", "testvault:Plans/secret plan.txt"], environment: try await rclone.environment(extra: try await vault.runtimeEnvironment()))
            #expect(back.stdout == "top secret contents")

            // Lock forgets the password; opening then fails clearly.
            try vault.lock()
            await #expect(throws: DriveError.self) { _ = try await vault.runtimeEnvironment() }
        }
    }
}
