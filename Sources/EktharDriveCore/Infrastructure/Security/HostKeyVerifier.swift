import Foundation

public struct HostKey: Sendable, Equatable, Identifiable {
    /// The known_hosts line, e.g. `[host]:2222 ssh-ed25519 AAAA...`.
    public var knownHostsLine: String
    public var keyType: String
    /// `SHA256:...` as printed by `ssh-keygen -l`.
    public var fingerprint: String
    public var id: String { fingerprint }
}

/// Fetches a server's SSH host keys and manages the app's own known_hosts file (0600).
/// rclone is pointed at that file with `known_hosts_file`, so it refuses any key that is not listed.
public struct HostKeyVerifier: Sendable {
    public let knownHostsURL: URL
    private let runner: ProcessRunning

    public init(knownHostsURL: URL, runner: ProcessRunning = ProcessRunner()) {
        self.knownHostsURL = knownHostsURL
        self.runner = runner
    }

    public static func hostPattern(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    /// Asks the server for its host keys (`ssh-keyscan`). The user must compare a fingerprint with the server
    /// out of band before trusting it.
    public func scan(host: String, port: Int, timeoutSeconds: Int = 10) async throws(DriveError) -> [HostKey] {
        let result: ProcessResult
        do {
            result = try await runner.run(URL(fileURLWithPath: "/usr/bin/ssh-keyscan"),
                                          arguments: ["-T", String(timeoutSeconds), "-p", String(port), "--", host],
                                          timeout: .seconds(timeoutSeconds + 5))
        } catch {
            throw .unknown("ssh-keyscan could not run.")
        }
        let lines = result.stdout.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
        guard !lines.isEmpty else {
            throw .remoteUnavailable("No SSH host key received from \(host):\(port). Check the address, port and the VM's security list / firewall.")
        }
        var keys: [HostKey] = []
        for line in lines {
            if let fp = try await fingerprint(of: line) {
                let type = line.split(separator: " ").dropFirst().first.map(String.init) ?? "unknown"
                keys.append(HostKey(knownHostsLine: line, keyType: type, fingerprint: fp))
            }
        }
        return keys.sorted { Self.rank($0.keyType) < Self.rank($1.keyType) }
    }

    private static func rank(_ type: String) -> Int {
        switch type {
        case "ssh-ed25519": 0
        case let t where t.hasPrefix("ecdsa"): 1
        default: 2
        }
    }

    func fingerprint(of knownHostsLine: String) async throws(DriveError) -> String? {
        let r = try? await runner.run(URL(fileURLWithPath: "/usr/bin/ssh-keygen"), arguments: ["-l", "-f", "/dev/stdin"],
                                      stdin: Data((knownHostsLine + "\n").utf8), timeout: .seconds(10))
        guard let out = r?.stdout, let fp = out.split(separator: " ").first(where: { $0.hasPrefix("SHA256:") }) else { return nil }
        return String(fp)
    }

    /// Replaces any entries for this host with `keys` and writes the file 0600.
    public func trust(_ keys: [HostKey], host: String, port: Int) throws(DriveError) {
        let pattern = Self.hostPattern(host: host, port: port)
        var lines = existingLines().filter { $0.split(separator: " ").first.map(String.init) != pattern }
        for key in keys {
            var parts = key.knownHostsLine.split(separator: " ").map(String.init)
            guard parts.count >= 3 else { continue }
            parts[0] = pattern
            lines.append(parts.prefix(3).joined(separator: " "))
        }
        let text = lines.joined(separator: "\n") + "\n"
        do {
            try Data(text.utf8).write(to: knownHostsURL, options: .atomic)
            try FilePermissions.set(knownHostsURL.path, mode: 0o600)
        } catch {
            throw .permissionDenied("Could not write \(knownHostsURL.path).")
        }
    }

    public func forget(host: String, port: Int) throws(DriveError) {
        try trust([], host: host, port: port)
    }

    public func trustedFingerprints(host: String, port: Int) async -> [String] {
        let pattern = Self.hostPattern(host: host, port: port)
        var fps: [String] = []
        for line in existingLines() where line.split(separator: " ").first.map(String.init) == pattern {
            if let fp = try? await fingerprint(of: line) { fps.append(fp) }
        }
        return fps
    }

    public func isTrusted(host: String, port: Int) -> Bool {
        let pattern = Self.hostPattern(host: host, port: port)
        return existingLines().contains { $0.split(separator: " ").first.map(String.init) == pattern }
    }

    private func existingLines() -> [String] {
        guard let text = try? String(contentsOf: knownHostsURL, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }
}
