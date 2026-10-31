import Foundation

/// Removes credentials from any text before it is logged, displayed or exported.
public enum Redactor {
    private static let rules: [(NSRegularExpression, String)] = {
        let specs: [(String, String)] = [
            // PEM / OpenSSH private key blocks
            (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, "[REDACTED PRIVATE KEY]"),
            // JSON style "access_token":"..." / "refresh_token": "..."
            (#"("(?:access_token|refresh_token|id_token|client_secret|password|pass|key_file_pass|token)"\s*:\s*")[^"]*(")"#, "$1[REDACTED]$2"),
            // rclone.conf / CLI key=value or key = value
            (#"(?i)\b(token|client_secret|pass|password|key_file_pass|key_pem|access_token|refresh_token)(\s*=\s*)\S.*"#, "$1$2[REDACTED]"),
            // --flag value / --flag=value for secret flags
            (#"(--(?:rc-pass|password|pass|client-secret|drive-client-secret|sftp-pass|sftp-key-file-pass|sftp-key-pem|token)(?:=|\s+))\S+"#, "$1[REDACTED]"),
            // Environment assignments for secrets
            (#"\b(RCLONE_CONFIG_PASS|RCLONE_[A-Z_]*(?:PASS|SECRET|TOKEN|KEY_PEM))=\S+"#, "$1=[REDACTED]"),
            // Google OAuth tokens and HTTP auth headers
            (#"\bya29\.[A-Za-z0-9_\-\.]+"#, "[REDACTED]"),
            (#"\b1//[A-Za-z0-9_\-]{20,}"#, "[REDACTED]"),
            (#"(?i)(authorization:\s*(?:bearer|basic)\s+)\S+"#, "$1[REDACTED]"),
            (#"(?i)([?&](?:code|state|access_token|token)=)[^&\s"]+"#, "$1[REDACTED]"),
            (#"\bGOCSPX-[A-Za-z0-9_\-]+"#, "[REDACTED]"),
        ]
        return specs.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
        }
    }()

    public static func redact(_ text: String) -> String {
        var result = text
        for (regex, template) in rules {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }
}
