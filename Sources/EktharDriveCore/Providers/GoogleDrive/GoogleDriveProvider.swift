import Foundation

/// Google Drive via rclone's `drive` backend with full `drive` scope (needed to see files this app did not create).
///
/// Secrets:
/// - OAuth access/refresh token: written by rclone into rclone.conf, which is encrypted with a Keychain-held password.
/// - Optional own OAuth client secret: Keychain only; given to rclone through `RCLONE_DRIVE_CLIENT_SECRET` in the
///   child environment, never written to rclone.conf or passed as an argument.
public struct GoogleDriveProvider: Sendable {
    public let rclone: RcloneService
    public let remoteName: String
    private let logger = AppLogger(category: "google")

    public static let scope = "drive"
    public static let authURLPattern = #"http://127\.0\.0\.1:53682/auth\?state=[A-Za-z0-9_\-]+"#

    public init(rclone: RcloneService, remoteName: String = "gdrive") {
        self.rclone = rclone
        self.remoteName = remoteName
    }

    public func isConfigured() async -> Bool { await rclone.remoteExists(remoteName) }

    /// Extra environment every gdrive rclone process needs.
    public func runtimeEnvironment() throws(DriveError) -> [String: String] {
        guard let secret = try rclone.secrets.get(.googleClientSecret), !secret.isEmpty else { return [:] }
        return ["RCLONE_DRIVE_CLIENT_SECRET": secret]
    }

    /// Runs the OAuth flow. rclone starts a loopback listener on 127.0.0.1:53682 and opens the browser;
    /// `onAuthURL` receives the same link so the UI can show it if the browser did not open.
    /// Returns only after rclone stored a token AND a real API call succeeded.
    public func connect(clientID: String?, clientSecret: String?, onAuthURL: @escaping @Sendable (URL) -> Void) async throws(DriveError) -> StorageUsage {
        try await rclone.ensureEncryptedConfig()
        if let clientSecret, !clientSecret.isEmpty {
            try rclone.secrets.set(clientSecret, for: .googleClientSecret)
        } else {
            try rclone.secrets.delete(.googleClientSecret)
        }
        var options: [(String, String)] = [("scope", Self.scope)]
        if let clientID, !clientID.isEmpty {
            guard clientID.hasSuffix(".apps.googleusercontent.com") else {
                throw .invalidConfiguration("A Google OAuth client ID ends with .apps.googleusercontent.com.")
            }
            options.append(("client_id", clientID))
        }
        let regex = try? NSRegularExpression(pattern: Self.authURLPattern)
        let reported = Locked(false)
        let onOutput: @Sendable (String) -> Void = { chunk in
            guard let regex, !reported.current,
                  let m = regex.firstMatch(in: chunk, range: NSRange(chunk.startIndex..., in: chunk)),
                  let r = Range(m.range, in: chunk), let url = URL(string: String(chunk[r])) else { return }
            reported.withLock { $0 = true }
            onAuthURL(url)
        }
        if await rclone.remoteExists(remoteName) { try await rclone.deleteRemote(remoteName) }
        var args = ["config", "create", remoteName, "drive"]
        for (k, v) in options { args += [k, v] }
        let r = try await rclone.run(args, environment: try rclone.environment(extra: try runtimeEnvironment()),
                                     timeout: .seconds(600), onOutput: onOutput)
        if r.timedOut {
            try? await rclone.deleteRemote(remoteName)
            throw .timeout("Google sign-in was not completed within 10 minutes.")
        }
        guard r.exitCode == 0 else {
            try? await rclone.deleteRemote(remoteName)
            throw ErrorClassifier.classify(output: r.combinedLines, exitCode: r.exitCode, host: "Google")
        }
        // Prove it works with a real API call; never report success on rclone's exit code alone.
        do {
            let usage = try await self.usage()
            logger.notice("Google Drive connected")
            return usage
        } catch {
            throw .authenticationFailed("Sign-in finished but Google Drive did not accept the token: \(error.detail)")
        }
    }

    public func usage() async throws(DriveError) -> StorageUsage {
        try await rclone.about("\(remoteName):", host: "Google Drive", extraEnv: try runtimeEnvironment())
    }

    public func testConnection() async throws(DriveError) {
        try await rclone.testConnection("\(remoteName):", host: "Google Drive", extraEnv: try runtimeEnvironment())
    }

    public func accountLabel() async -> String? {
        let info = await rclone.userInfo(remoteName)
        return info["Email"] ?? info["email"] ?? info["Name"]
    }

    /// Revokes the refresh token at Google (best effort) and removes the remote and client secret.
    public func disconnect(revoke: Bool = true) async throws(DriveError) -> Bool {
        var revoked = false
        if revoke, let tokenJSON = try? await rclone.secretOption(remoteName, key: "token"),
           let obj = try? JSONSerialization.jsonObject(with: Data(tokenJSON.utf8)) as? [String: Any],
           let token = (obj["refresh_token"] as? String) ?? (obj["access_token"] as? String) {
            revoked = await Self.revoke(token: token)
        }
        try await rclone.deleteRemote(remoteName)
        try rclone.secrets.delete(.googleClientSecret)
        logger.notice("Google Drive disconnected (revoked=\(revoked))")
        return revoked
    }

    static func revoke(token: String) async -> Bool {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = Data("token=\(token.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")".utf8)
        req.timeoutInterval = 15
        guard let (_, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }
}
