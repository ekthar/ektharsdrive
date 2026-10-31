# Security

## What protects what

| Asset | Protection |
|---|---|
| Google OAuth token | Written by rclone into the app's own `rclone.conf`, which is encrypted at rest by rclone (`RCLONE_ENCRYPT_V0`, NaCl secretbox) and mode 0600. The encryption password is 32 random bytes in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). |
| Own Google OAuth client secret (optional) | Keychain only. Passed to rclone as `RCLONE_DRIVE_CLIENT_SECRET` in the child environment. Never in rclone.conf, never in argv. Note that Google treats desktop client secrets as non-confidential. |
| SSH private key | Stays where you keep it (e.g. `~/.ssh`). The app stores only its path. The passphrase, if any, is kept in the Keychain and given to rclone obscured via `RCLONE_SFTP_KEY_FILE_PASS`. |
| SSH server identity | `ssh-keyscan` fetches the host key, and you compare the SHA256 fingerprint with the server out of band. Only then is it written to the app's `known_hosts`. rclone runs with `known_hosts_file` and refuses mismatches (`knownhosts: key mismatch`). A mismatch never auto-retries and blocks auto-mount. |
| rclone control API | Unix socket in a 0700 directory. No TCP listener, no password on the command line. |
| NFS engine | rclone's NFS server binds to 127.0.0.1 only. |
| Logs / activity / diagnostics | Every line passes through `Redactor` before it is written (tokens, `ya29.` / `1//` Google tokens, `GOCSPX-` secrets, private-key blocks, `key = value` secrets, secret flags and env vars, OAuth `code` / `state` query params). |
| Child processes | Run with argv arrays (never a shell) and a minimal environment, so unrelated secrets in the app's environment are not inherited. |

Restrictions also enforced in code: SFTP user `root` is refused, mount paths cannot be system directories or your home folder, remote paths cannot contain `..`, and no temporary files hold secrets.

## Encryption: what it does and does not mean

- **In transit:** Google Drive uses HTTPS (TLS). Oracle uses SSH.
- **At rest on the provider:** Google encrypts stored data with Google-held keys. Oracle block volumes are encrypted by Oracle. Either provider can technically read your files.
- **Client-side / end-to-end:** **not provided.** Ekthar Drive does not claim end-to-end encryption. For that, put an audited tool such as [Cryptomator](https://cryptomator.org) vault inside a mounted volume, or use an rclone `crypt` remote (planned, not built).
- **Local cache:** cached file contents in `~/Library/Caches/EktharDrive` are plain files protected by your account permissions (0700). Turn on **FileVault** so they are encrypted at rest on this Mac.

## Reporting

This is a personal project. Open an issue privately with the maintainer; do not attach diagnostics without checking them, even though they are redacted.
