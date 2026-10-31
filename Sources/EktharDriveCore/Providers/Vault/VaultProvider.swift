import Foundation

/// An encrypted folder inside Google Drive, using rclone's `crypt` backend (XSalsa20-Poly1305 for
/// contents, EME/AES-256 for names). Google only ever sees encrypted names and bytes.
///
/// The password is the only key. It lives in the Keychain and reaches rclone through the child's
/// environment (`RCLONE_CONFIG_VAULT_PASSWORD`, obscured the way rclone expects). rclone.conf holds the
/// remote's shape but no password, so the config alone cannot open the vault. rclone's built-in salt is
/// used, so the password alone recovers the files with any copy of rclone.
public struct VaultProvider: Sendable {
    public let rclone: RcloneService
    public let remoteName: String
    /// The Google remote the vault lives in, e.g. "gdrive".
    public let baseRemote: String
    /// Folder in Google Drive holding the encrypted files.
    public let folder: String
    /// Extra environment the Google remote needs (its client secret).
    public let baseEnvironment: [String: String]

    public static let defaultFolder = "Ekthar Vault"
    public static let minimumPasswordLength = 12

    public init(rclone: RcloneService, remoteName: String = "vault", baseRemote: String = "gdrive",
                folder: String = VaultProvider.defaultFolder, baseEnvironment: [String: String] = [:]) {
        self.rclone = rclone
        self.remoteName = remoteName
        self.baseRemote = baseRemote
        self.folder = folder
        self.baseEnvironment = baseEnvironment
    }

    public var underlying: String { "\(baseRemote):\(folder)" }

    /// Plain rules a password must meet. Returns the problem, or nil when it is acceptable.
    public static func passwordProblem(_ password: String, confirm: String) -> String? {
        if password.count < minimumPasswordLength { return "Use at least \(minimumPasswordLength) characters." }
        if password != confirm { return "The two passwords do not match." }
        if Set(password).count < 5 { return "Use more different characters." }
        return nil
    }

    public func hasSavedPassword() -> Bool { ((try? rclone.secrets.get(.vaultPassword)) ?? nil)?.isEmpty == false }

    /// Environment for any rclone process that opens the vault.
    public func runtimeEnvironment(password: String? = nil) async throws(DriveError) -> [String: String] {
        let saved: String? = password == nil ? try rclone.secrets.get(.vaultPassword) : nil
        guard let pass = password ?? saved, !pass.isEmpty else {
            throw .authenticationFailed("The vault is locked. Enter its password in Settings > Accounts.")
        }
        var env = baseEnvironment
        env["RCLONE_CONFIG_\(remoteName.uppercased())_PASSWORD"] = try await rclone.obscure(pass)
        return env
    }

    /// Creates the vault remote (or reconnects to an existing vault folder) and saves the password.
    /// For an existing folder, refuses a password that cannot read its names: nothing is written then.
    public func configure(password: String) async throws(DriveError) {
        try await rclone.ensureEncryptedConfig()
        if await rclone.remoteExists(remoteName) { try await rclone.deleteRemote(remoteName) }
        try await rclone.createRemote(remoteName, type: "crypt", options: [
            ("remote", underlying), ("filename_encryption", "standard"), ("directory_name_encryption", "true"),
        ])
        let env = try await runtimeEnvironment(password: password)
        do {
            try await checkPassword(env: env)
        } catch {
            try? await rclone.deleteRemote(remoteName)
            throw error
        }
        try rclone.secrets.set(password, for: .vaultPassword)
    }

    /// An existing vault folder with items whose names do not decrypt means the wrong password.
    func checkPassword(env: [String: String]) async throws(DriveError) {
        let base = try await rclone.environment(extra: baseEnvironment)
        let raw = try await rclone.run(["lsf", underlying, "--max-depth", "1"], environment: base, timeout: .seconds(60))
        // A missing folder is a new vault: create it so the first mount has somewhere to write.
        if raw.exitCode != 0 {
            let made = try await rclone.run(["mkdir", underlying], environment: base, timeout: .seconds(60))
            guard made.exitCode == 0 else {
                throw ErrorClassifier.classify(output: made.combinedLines, exitCode: made.exitCode, host: "Google Drive")
            }
            return
        }
        let rawCount = raw.stdout.split(whereSeparator: \.isNewline).count
        guard rawCount > 0 else { return }
        let opened = try await rclone.run(["lsf", "\(remoteName):", "--max-depth", "1"], environment: try await rclone.environment(extra: env), timeout: .seconds(60))
        let readable = opened.stdout.split(whereSeparator: \.isNewline).count
        if readable == 0 {
            throw .authenticationFailed("That password does not open the vault folder “\(folder)” in Google Drive. Its \(rawCount) item\(rawCount == 1 ? "" : "s") stay untouched.")
        }
    }

    public func testConnection() async throws(DriveError) {
        try await rclone.testConnection("\(remoteName):", host: "Google Drive", extraEnv: try await runtimeEnvironment())
    }

    /// Google's numbers for the whole account (a folder has no own quota).
    public func usage() async throws(DriveError) -> StorageUsage {
        try await rclone.about("\(baseRemote):", host: "Google Drive", extraEnv: baseEnvironment)
    }

    /// Removes the remote and the saved password from this Mac. The encrypted files stay in Google Drive.
    public func disconnect() async throws(DriveError) {
        try await rclone.deleteRemote(remoteName)
        try rclone.secrets.delete(.vaultPassword)
    }

    /// Forgets the saved password but keeps the setup, so the vault needs the password to open again.
    public func lock() throws(DriveError) { try rclone.secrets.delete(.vaultPassword) }
}
