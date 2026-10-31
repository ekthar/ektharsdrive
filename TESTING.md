# Testing

```bash
# Unit tests (no network, no rclone needed). Uses the real login Keychain under a throwaway service name.
swift test --disable-sandbox --filter UnitTests

# Integration tests: real rclone + real SFTP server on 127.0.0.1 + real macOS NFS mount.
EKTHAR_RCLONE=/path/to/official/rclone swift test --disable-sandbox --filter IntegrationTests
```

`--disable-sandbox` is only needed when the build already runs inside a sandbox. `EKTHAR_TEST_ROOT=<short dir>` keeps Unix socket paths under the 104-byte limit if your temp dir is long. Integration tests are skipped when `EKTHAR_RCLONE` is not set.

## What the integration tests prove

The Oracle stand-in is `rclone serve sftp` with its own ed25519 host key and public-key-only auth, driven through `DriveManager` exactly as the app drives it.

| Test | Covers |
|---|---|
| `fullLifecycleOnRealMount` | Host-key fetch and trust, real connection test, real capacity, encrypted 0600 config, mount. Then: listing, reading, 32 MB download SHA-256, create/write, Unicode names, 64 MB upload SHA-256 compared on the server, rename, move, delete, transfer history from rclone, live cache stats, **unmount refused while a write is pending**, wait-then-unmount with the pending file verified on the server, and no secrets in logs. |
| `hostKeyMismatchIsRefusedAndNeverRetried` | A wrong key is rejected with `hostKeyMismatch`. The drive is `failed` with no retry. An untrusted host is refused before rclone launches. |
| `invalidKeyIsAuthenticationFailure` | An unknown client key gives `authenticationFailed`. |
| `uploadSurvivesServerOutageAndReconnects` | The server dies before the write-back upload. The volume stays mounted, the upload stays pending, and after the server returns it completes with an identical SHA-256. |
| `unreachableServerRetriesWithBackoff` | Mounting with the server down leads to `retrying`. When the server comes back, a scheduled retry mounts it. |
| `twoIndependentMounts` | Two drives, two processes, two mount points. A duplicate mount is refused. Unmounting one leaves the other working. |
| `occupiedMountPointIsRefused` | A non-empty folder at the mount path is refused, and the user's file is untouched. |
| `relaunchAdoptsRunningMount` | A second app instance reattaches to the running rclone (same PID) and unmounts it cleanly. |
| `versionDetectionAndEncryptedConfig` | rclone version and build-tag probing, idempotent encryption, wrong password gives a typed error rather than a hang. |

## Not covered by automated tests

- **Google Drive against a real account.** This needs your OAuth sign-in. The code path is shared with SFTP except for `GoogleDriveProvider`.
- **macFUSE engine.** macFUSE is not installed on the development Mac. Argument building is unit-tested only.
- **UI.** No UI automation. The app was built, launched and quit to check it starts and creates its data directory with 0700/0600 permissions.
- **Sleep/wake and real network loss.** Covered only through the same code paths as server outage (`reconnectAfterInterruption`).
