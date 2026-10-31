import Foundation

/// Maps rclone output (stderr/JSON log lines) to typed `DriveError`s.
/// Patterns were taken from real rclone 1.75 output observed during development.
public enum ErrorClassifier {
    public static func classify(output lines: [String], exitCode: Int32? = nil, host: String? = nil) -> DriveError {
        let text = lines.joined(separator: "\n")
        let lower = text.lowercased()
        let hostName = host ?? "the server"

        if lower.contains("knownhosts: key mismatch") || lower.contains("host key mismatch") {
            return .hostKeyMismatch(host: hostName)
        }
        if lower.contains("knownhosts: key is unknown") {
            return .hostKeyUnknown(host: hostName)
        }
        if let google = googleAPIError(text) { return google }
        let authMarkers = ["invalid_grant", "token has been expired or revoked", "couldn't fetch token", "oauth2: cannot fetch token",
                           "token expired", "unable to authenticate", "no supported methods remain", "permission denied (publickey",
                           "ssh: handshake failed: ssh: unable to authenticate", "unauthorized_client", "invalid_client",
                           "failed to read private key", "this private key is passphrase protected", "x509: certificate"]
        if let marker = authMarkers.first(where: { lower.contains($0) }) {
            return .authenticationFailed(friendlyAuth(marker))
        }
        if lower.contains("no space left on device") {
            return .localDiskFull(freeBytes: 0)
        }
        if lower.contains("file system extension not enabled") {
            return .dependencyMissing(.macFUSE, detail: "macFUSE is installed but its file system extension is turned off. Turn on macFUSE in System Settings > General > Login Items & Extensions > File System Extensions, or switch to the Built-in NFS engine.")
        }
        if lower.contains("failed to retrieve mount path information") || lower.contains("mount stopped before calling init") {
            return .dependencyMissing(.macFUSE, detail: "macFUSE is installed but could not create the volume. Turn on macFUSE in System Settings > General > Login Items & Extensions > File System Extensions, or use the Built-in NFS engine.")
        }
        if lower.contains("failed to exec mount program") {
            return .dependencyMissing(.macFUSE, detail: "macOS did not allow the macFUSE mount helper to run. Approve macFUSE in System Settings > Privacy & Security, or switch to the Built-in NFS engine.")
        }
        if lower.contains("cannot find fuse") || lower.contains("libfuse") || lower.contains("fuse: device not found")
            || lower.contains("mount helper error") || lower.contains("osxfuse") || lower.contains("macfuse") {
            return .dependencyMissing(.macFUSE, detail: "macFUSE is required for this mount engine. Install it from macfuse.github.io, or switch to the Built-in NFS engine in Settings > Advanced.")
        }
        if lower.contains("unknown command \"mount\"") || lower.contains("mount is not supported") || lower.contains("rclone mount is not supported") {
            return .dependencyMissing(.rcloneMountSupport, detail: "This rclone build was compiled without mount support (Homebrew builds are). Use the official rclone binary or the Built-in NFS engine.")
        }
        if lower.contains("directory already mounted") || lower.contains("mountpoint is not empty") || lower.contains("directory is not empty") {
            return .mountPointOccupied(path: "", by: "existing files or another mount")
        }
        if lower.contains("resource busy") {
            return .mountPointBusy(path: "")
        }
        let networkMarkers = ["no such host", "network is unreachable", "dial tcp", "connection refused", "i/o timeout",
                              "connection reset by peer", "tls handshake timeout", "context deadline exceeded",
                              "couldn't connect ssh", "broken pipe", "eof"]
        if lower.contains("network is unreachable") || lower.contains("no route to host") {
            return .networkUnavailable
        }
        if let marker = networkMarkers.first(where: { lower.contains($0) }) {
            return .remoteUnavailable("Could not reach \(hostName) (\(marker)).")
        }
        if lower.contains("quota") && lower.contains("exceeded") {
            return .remoteUnavailable("The provider reported that a quota was exceeded. Uploads will retry automatically.")
        }
        if let exitCode {
            let last = lastMeaningfulLine(lines) ?? "No error output."
            return .processExited(code: exitCode, detail: last)
        }
        return .unknown(lastMeaningfulLine(lines) ?? "No error output.")
    }

    /// Google API errors arrive as multi-line JSON (`"reason": "SERVICE_DISABLED"`, `"message": "..."`) or as
    /// `googleapi: Error 403: <message>, <reason>`. Turn the common ones into a fix the user can act on.
    static func googleAPIError(_ text: String) -> DriveError? {
        func first(_ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
        let reason = first(#""reason"\s*:\s*"([A-Za-z_]+)""#) ?? first(#"googleapi: Error \d+: [^\n]*?, ([A-Za-z]+)\b"#)
        let message = first(#""message"\s*:\s*"([^"]+)""#) ?? first(#"googleapi: Error \d+: ([^\n]+)"#)
        let project = first(#"project[s]?[ /=:]+(\d{6,})"#)
        guard reason != nil || (message?.contains("googleapis") ?? false) || text.contains("googleapi: Error") else { return nil }
        let enableLink = "https://console.cloud.google.com/apis/library/drive.googleapis.com" + (project.map { "?project=\($0)" } ?? "")
        switch reason?.uppercased() ?? "" {
        case "SERVICE_DISABLED", "ACCESSNOTCONFIGURED":
            return .authenticationFailed("The Google Drive API is turned off for your Google Cloud project\(project.map { " (\($0))" } ?? ""). Open \(enableLink), click Enable, wait a minute, then sign in again.")
        case "ACCESS_TOKEN_SCOPE_INSUFFICIENT", "INSUFFICIENTPERMISSIONS":
            return .authenticationFailed("Google gave the app too little access. On your consent screen (Data Access), add the scope https://www.googleapis.com/auth/drive, then sign in again and allow every checkbox.")
        case "RATELIMITEXCEEDED", "USERRATELIMITEXCEEDED", "RATE_LIMIT_EXCEEDED", "QUOTAEXCEEDED":
            return .remoteUnavailable("Google is rate-limiting requests right now. Ekthar Drive retries automatically.")
        case "STORAGEQUOTAEXCEEDED":
            return .remoteUnavailable("Your Google storage is full. Free space in Google Drive to upload more.")
        case "AUTHERROR", "UNAUTHENTICATED", "INVALIDCREDENTIALS":
            return .authenticationFailed("Google rejected the sign-in. Reconnect your Google account.")
        default:
            guard let message else { return nil }
            return .remoteUnavailable("Google said: \(Redactor.redact(message))\(reason.map { " (\($0))" } ?? "")")
        }
    }

    private static func friendlyAuth(_ marker: String) -> String {
        switch marker {
        case "invalid_grant", "token has been expired or revoked", "couldn't fetch token", "oauth2: cannot fetch token", "token expired":
            "Google rejected the saved sign-in. It may have been revoked or expired. Reconnect your Google account."
        case "unauthorized_client", "invalid_client":
            "Google rejected the OAuth client ID. Check the client ID and secret in Settings > Accounts."
        case "this private key is passphrase protected":
            "The SSH private key needs a passphrase. Enter it in the Oracle configuration."
        case "failed to read private key":
            "The SSH private key could not be read. Check the key path and its permissions."
        default:
            "The server rejected the SSH key. Make sure the public key is in the SFTP user's authorized_keys."
        }
    }

    /// Last log line that looks like an error, with rclone's timestamp prefix removed.
    public static func lastMeaningfulLine(_ lines: [String]) -> String? {
        let candidates = lines.reversed().map(LogLine.message(from:)).filter { !$0.isEmpty }
        return candidates.first { $0.lowercased().contains("error") || $0.lowercased().contains("critical") || $0.lowercased().contains("failed") }
            ?? candidates.first
    }
}

/// Helpers for rclone log lines. rclone with `--use-json-log` writes `{"level":..,"msg":..}` per line.
public enum LogLine {
    public struct Parsed: Sendable, Equatable {
        public var level: String
        public var message: String
        public var object: String?
    }

    public static func parse(_ line: String) -> Parsed {
        if line.hasPrefix("{"), let data = line.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let level = (obj["level"] as? String) ?? "info"
            let msg = (obj["msg"] as? String) ?? line
            return Parsed(level: level, message: msg.trimmingCharacters(in: .whitespacesAndNewlines), object: obj["object"] as? String)
        }
        // Text format: "2026/10/31 11:39:33 NOTICE: message"
        let pattern = #"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}(\.\d+)? ([A-Z]+)\s*: ?(.*)$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let lr = Range(m.range(at: 2), in: line), let mr = Range(m.range(at: 3), in: line) {
            return Parsed(level: String(line[lr]).lowercased(), message: String(line[mr]), object: nil)
        }
        return Parsed(level: "info", message: line.trimmingCharacters(in: .whitespacesAndNewlines), object: nil)
    }

    public static func message(from line: String) -> String { parse(line).message }
}
