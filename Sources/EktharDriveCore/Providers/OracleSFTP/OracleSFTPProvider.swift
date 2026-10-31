import Foundation

/// Oracle Cloud VM over SFTP (rclone `sftp` backend) with public-key auth and strict host-key checking
/// against the app's own known_hosts file. Never connects as root and never modifies the server.
public struct OracleSFTPProvider: Sendable {
    public let rclone: RcloneService
    public let verifier: HostKeyVerifier
    public let remoteName: String
    private let logger = AppLogger(category: "oracle")

    public init(rclone: RcloneService, verifier: HostKeyVerifier, remoteName: String = "oracle") {
        self.rclone = rclone
        self.verifier = verifier
        self.remoteName = remoteName
    }

    public func isConfigured() async -> Bool { await rclone.remoteExists(remoteName) }

    public func scanHostKeys(host: String, port: Int) async throws(DriveError) -> [HostKey] {
        try await verifier.scan(host: host, port: port)
    }

    /// Saves the remote. Requires the host key to have been verified and trusted first.
    public func configure(_ c: SFTPConnection, passphrase: String?) async throws(DriveError) {
        try c.validate()
        guard verifier.isTrusted(host: c.host, port: c.port) else { throw .hostKeyUnknown(host: c.host) }
        try await rclone.ensureEncryptedConfig()
        if c.keyHasPassphrase, let passphrase, !passphrase.isEmpty {
            try rclone.secrets.set(passphrase, for: .oracleKeyPassphrase)
        } else if !c.keyHasPassphrase {
            try rclone.secrets.delete(.oracleKeyPassphrase)
        }
        if await rclone.remoteExists(remoteName) { try await rclone.deleteRemote(remoteName) }
        try await rclone.createRemote(remoteName, type: "sftp", options: [
            ("host", c.host), ("port", String(c.port)), ("user", c.username),
            ("key_file", c.privateKeyPath), ("known_hosts_file", verifier.knownHostsURL.path),
        ])
        logger.notice("Oracle SFTP remote configured for \(c.username)@\(c.host):\(c.port)")
    }

    /// Key passphrase for the child process, obscured the way rclone expects. Never in args or rclone.conf.
    public func runtimeEnvironment() async throws(DriveError) -> [String: String] {
        guard let pass = try rclone.secrets.get(.oracleKeyPassphrase), !pass.isEmpty else { return [:] }
        return ["RCLONE_SFTP_KEY_FILE_PASS": try await rclone.obscure(pass)]
    }

    public func testConnection(remotePath: String, host: String) async throws(DriveError) {
        try await rclone.testConnection("\(remoteName):\(remotePath)", host: host, extraEnv: try await runtimeEnvironment())
    }

    /// Real filesystem capacity of the remote directory (SFTP statvfs / df over SSH, via rclone `about`).
    public func usage(remotePath: String, host: String) async throws(DriveError) -> StorageUsage {
        try await rclone.about("\(remoteName):\(remotePath)", host: host, extraEnv: try await runtimeEnvironment())
    }

    public func disconnect(host: String?, port: Int?) async throws(DriveError) {
        try await rclone.deleteRemote(remoteName)
        try rclone.secrets.delete(.oracleKeyPassphrase)
        if let host, let port { try verifier.forget(host: host, port: port) }
    }
}
