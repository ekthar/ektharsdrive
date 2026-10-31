import Foundation

/// A located rclone executable and what it can do.
public struct RcloneBinary: Sendable, Equatable {
    public var url: URL
    public var version: String
    /// Built with cmount (needed for `rclone mount` through macFUSE). Homebrew builds are not.
    public var supportsFUSEMount: Bool
    /// Has `nfsmount` (rclone >= 1.65; pure Go, works with any build).
    public var supportsNFSMount: Bool
}

/// Wraps every non-mount rclone invocation. All calls use the app-private, encrypted rclone.conf.
/// The config password comes from the Keychain and reaches rclone only through the child's environment.
public struct RcloneService: Sendable {
    public let paths: AppPaths
    public let secrets: SecretStore
    public let binary: RcloneBinary
    private let runner = ProcessRunner()
    private let logger = AppLogger(category: "rclone")

    public init(paths: AppPaths, secrets: SecretStore, binary: RcloneBinary) {
        self.paths = paths
        self.secrets = secrets
        self.binary = binary
    }

    // MARK: Locating

    public static func candidatePaths(paths: AppPaths, configured: String?) -> [URL] {
        var list: [String] = []
        if let configured, !configured.isEmpty { list.append((configured as NSString).expandingTildeInPath) }
        list += [paths.binDirectory.appendingPathComponent("rclone").path, "/usr/local/bin/rclone", "/opt/homebrew/bin/rclone",
                 FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("bin/rclone").path]
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }.map(URL.init(fileURLWithPath:))
    }

    /// Finds the first working rclone and probes its version and build tags.
    public static func locate(paths: AppPaths, configured: String?) async -> RcloneBinary? {
        for url in candidatePaths(paths: paths, configured: configured) where FileManager.default.isExecutableFile(atPath: url.path) {
            if let b = await probe(url) { return b }
        }
        return nil
    }

    public static func probe(_ url: URL) async -> RcloneBinary? {
        guard let r = try? await ProcessRunner().run(url, arguments: ["version"], timeout: .seconds(15)), r.exitCode == 0 else { return nil }
        let lines = r.stdout.split(whereSeparator: \.isNewline).map(String.init)
        guard let first = lines.first, first.hasPrefix("rclone ") else { return nil }
        let version = String(first.dropFirst("rclone ".count))
        let tags = lines.first { $0.contains("go/tags:") } ?? ""
        return RcloneBinary(url: url, version: version, supportsFUSEMount: tags.contains("cmount"),
                            supportsNFSMount: compare(version, atLeast: (1, 65)))
    }

    static func compare(_ version: String, atLeast min: (Int, Int)) -> Bool {
        let digits = version.drop { !$0.isNumber }.split(separator: ".").prefix(2).compactMap { Int($0.prefix { $0.isNumber }) }
        guard digits.count == 2 else { return false }
        return (digits[0], digits[1]) >= min
    }

    // MARK: Environment & config encryption

    /// Environment for any rclone child process.
    public func environment(extra: [String: String] = [:]) throws(DriveError) -> [String: String] {
        var env = SafeEnvironment.base(extra: ["RCLONE_CONFIG": paths.rcloneConfigURL.path])
        if let pass = try secrets.get(.rcloneConfigPassword) { env["RCLONE_CONFIG_PASS"] = pass }
        env.merge(extra) { _, new in new }
        return env
    }

    /// Makes sure rclone.conf exists, is 0600 and is encrypted with a random Keychain-held password.
    public func ensureEncryptedConfig() async throws(DriveError) {
        let url = paths.rcloneConfigURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
        try FilePermissions.set(url.path, mode: 0o600)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let encrypted = text.contains("RCLONE_ENCRYPT_V0:")
        if encrypted {
            guard try secrets.get(.rcloneConfigPassword) != nil else {
                throw .authenticationFailed("rclone.conf is encrypted but its password is missing from the Keychain. Remove the drive accounts in Settings > Accounts and connect again.")
            }
            return
        }
        let password = try secrets.get(.rcloneConfigPassword) ?? KeychainStore.randomPassword()
        try secrets.set(password, for: .rcloneConfigPassword)
        var env = SafeEnvironment.base(extra: ["RCLONE_CONFIG": url.path, "RCLONE_PASSWORD_CHANGE": "1", "EKTHAR_NEW_CONFIG_PASS": password])
        env["RCLONE_CONFIG_PASS"] = nil
        let r = try await run(["config", "encryption", "set", "--password-command", "/usr/bin/printenv EKTHAR_NEW_CONFIG_PASS"],
                              environment: env, timeout: .seconds(30))
        guard r.exitCode == 0, ((try? String(contentsOf: url, encoding: .utf8)) ?? "").contains("RCLONE_ENCRYPT_V0:") else {
            throw .unknown("Could not encrypt rclone.conf: \(Redactor.redact(ErrorClassifier.lastMeaningfulLine(r.combinedLines) ?? "unknown error"))")
        }
        try FilePermissions.set(url.path, mode: 0o600)
        logger.notice("rclone.conf encrypted")
    }

    // MARK: Generic run

    public func run(_ args: [String], environment: [String: String]? = nil, stdin: Data? = nil, timeout: Duration = .seconds(60),
                    onOutput: (@Sendable (String) -> Void)? = nil) async throws(DriveError) -> ProcessResult {
        let env: [String: String]
        if let environment { env = environment } else { env = try self.environment() }
        do {
            return try await runner.run(binary.url, arguments: args, environment: env, stdin: stdin, timeout: timeout, onOutput: onOutput)
        } catch let e as DriveError {
            throw e
        } catch {
            throw .unknown(error.localizedDescription)
        }
    }

    private func checked(_ r: ProcessResult, host: String? = nil, what: String) throws(DriveError) -> ProcessResult {
        if r.timedOut { throw .timeout("\(what) did not finish in time.") }
        guard r.exitCode == 0 else {
            let lines = r.combinedLines
            if lines.contains(where: { $0.contains("unable to decrypt configuration") }) {
                throw .authenticationFailed("The rclone configuration password in the Keychain does not match rclone.conf.")
            }
            throw ErrorClassifier.classify(output: lines, exitCode: r.exitCode, host: host)
        }
        return r
    }

    // MARK: Remotes

    public func listRemotes() async throws(DriveError) -> [String] {
        let r = try checked(try await run(["listremotes"], timeout: .seconds(20)), what: "Listing remotes")
        return r.stdout.split(whereSeparator: \.isNewline).map { String($0.dropLast($0.hasSuffix(":") ? 1 : 0)) }
    }

    public func remoteExists(_ name: String) async -> Bool {
        (try? await listRemotes().contains(name)) ?? false
    }

    /// Non-secret options of a remote (secrets are filtered out by key name).
    public func remoteOptions(_ name: String) async throws(DriveError) -> [String: String] {
        let r = try checked(try await run(["config", "dump"], timeout: .seconds(20)), what: "Reading configuration")
        guard let obj = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: [String: String]] else { return [:] }
        let secretKeys: Set<String> = ["token", "client_secret", "pass", "key_file_pass", "key_pem", "password"]
        return (obj[name] ?? [:]).filter { !secretKeys.contains($0.key) }
    }

    /// Reads one secret option (e.g. the OAuth token, for revocation). The value never leaves memory.
    func secretOption(_ name: String, key: String) async throws(DriveError) -> String? {
        let r = try checked(try await run(["config", "dump"], timeout: .seconds(20)), what: "Reading configuration")
        let obj = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: [String: String]]
        return obj?[name]?[key]
    }

    public func deleteRemote(_ name: String) async throws(DriveError) {
        guard await remoteExists(name) else { return }
        _ = try checked(try await run(["config", "delete", name], timeout: .seconds(20)), what: "Removing remote")
    }

    /// `rclone config create` with key/value pairs (argv, no shell). Never pass secrets here.
    public func createRemote(_ name: String, type: String, options: [(String, String)], timeout: Duration = .seconds(60),
                             onOutput: (@Sendable (String) -> Void)? = nil) async throws(DriveError) {
        var args = ["config", "create", name, type]
        for (k, v) in options { args += [k, v] }
        let r = try await run(args, timeout: timeout, onOutput: onOutput)
        _ = try checked(r, what: "Creating \(name)")
    }

    public func obscure(_ secret: String) async throws(DriveError) -> String {
        let r = try checked(try await run(["obscure", "-"], stdin: Data(secret.utf8), timeout: .seconds(10)), what: "Obscuring secret")
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Remote operations

    public func about(_ remoteSpec: String, host: String? = nil, extraEnv: [String: String] = [:], timeoutSeconds: Int = 15) async throws(DriveError) -> StorageUsage {
        let r = try await run(["about", remoteSpec, "--json", "--contimeout", "\(timeoutSeconds)s", "--timeout", "\(timeoutSeconds * 2)s",
                               "--low-level-retries", "1", "--retries", "1"],
                              environment: try environment(extra: extraEnv), timeout: .seconds(Int64(timeoutSeconds * 3)))
        _ = try checked(r, host: host, what: "Reading storage usage")
        guard let about = try? JSONDecoder().decode(RcAbout.self, from: Data(r.stdout.utf8)) else {
            throw .remoteUnavailable("The provider did not return storage usage.")
        }
        return about.usage
    }

    /// Lists the top level of the remote. Proves authentication + reachability without reading file contents.
    public func testConnection(_ remoteSpec: String, host: String? = nil, extraEnv: [String: String] = [:], timeoutSeconds: Int = 15) async throws(DriveError) {
        let r = try await run(["lsf", remoteSpec, "--max-depth", "1", "--dirs-only", "--contimeout", "\(timeoutSeconds)s",
                               "--timeout", "\(timeoutSeconds * 2)s", "--low-level-retries", "1", "--retries", "1"],
                              environment: try environment(extra: extraEnv), timeout: .seconds(Int64(timeoutSeconds * 4)))
        _ = try checked(r, host: host, what: "Connection test")
    }

    /// Account e-mail / name where the backend supports `config userinfo` (Google Drive does).
    public func userInfo(_ remoteName: String) async -> [String: String] {
        guard let r = try? await run(["config", "userinfo", "\(remoteName):", "--json"], timeout: .seconds(20)), r.exitCode == 0,
              let obj = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any] else { return [:] }
        return obj.compactMapValues { $0 as? String }
    }
}
