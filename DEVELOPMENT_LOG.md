# Development log

## 2026-10-31: first autonomous session

### Environment findings
- macOS 27.2 (26B123), Apple Silicon, Xcode 27.0 beta, Swift 6.4, 35 GB free on `/`.
- rclone was not installed; Homebrew's rclone cannot `mount` on macOS. I used the official v1.75.2 (`go/tags: cmount`).
- macFUSE is not installed and needs user approval of a system extension, so I did not install it.
- **`rclone nfsmount` works with no macFUSE and no root** (verified: mount, write, rename, Unicode, 50 MB SHA-256, unmount). It became the built-in fallback engine.
- `/Volumes` is root-owned, so NFS volumes go in `~/Volumes`.
- SwiftPM must run with `--disable-sandbox` inside this agent's sandbox.

### Decisions
- Unix-socket rc instead of a TCP port with a password: no network exposure, no secret in argv.
- Encrypted app-private rclone.conf, with the password in the Keychain and passed via the child env.
- PID files + argv check via `KERN_PROCARGS2` to reattach after a crash. `ps` truncated the command line and broke adoption until I replaced it.
- The cache size shown is the larger of rclone's `bytesUsed` and an on-disk measurement, because rclone refreshes `bytesUsed` only once a minute.

### Bugs found by the real-mount tests and fixed
- The transfer tracker ignored transfers that finished before the first poll of a fresh process (the history-seeding logic was meant only for reattached processes).
- Cache bytes read 0 right after writes (the rclone poll interval).
- Process adoption never matched (truncated `ps` output).
- Test cleanup ran in a detached task and leaked a mount. It now runs inline, always.

## Requirement status

| Area | Requirement | Status |
|---|---|---|
| App | Native SwiftUI app, sidebar, toolbar, light/dark | IMPLEMENTED (built, launched; no UI automation) |
| App | Dashboard, drive pages, Transfers, Cache, Activity, Settings, About | IMPLEMENTED |
| App | Menu bar with live state and working actions | IMPLEMENTED |
| App | Setup wizard (8 steps, real checks only) | IMPLEMENTED |
| Google | OAuth via rclone (scope `drive`), optional own client, token in encrypted config | IMPLEMENTED, **BLOCKED for testing**: needs your Google sign-in |
| Google | Capacity from the API, account label, revoke on disconnect | IMPLEMENTED, BLOCKED (same) |
| Google | Independent mount, Finder browsing, upload/download | IMPLEMENTED (same engine as Oracle); BLOCKED for real-account test |
| Oracle | SSH key auth, non-root enforced | TESTED (local SFTP server) |
| Oracle | Host-key fetch, user verification, mismatch refusal | TESTED |
| Oracle | Real capacity (statvfs via `rclone about`) | TESTED (local filesystem) |
| Oracle | Mount, browse, read, write, rename, move, delete, Unicode | TESTED |
| Oracle | Against your actual VM | BLOCKED: needs the VM address and an SFTP user (script provided) |
| Filesystem | NFS engine | TESTED |
| Filesystem | macFUSE engine | IMPLEMENTED, BLOCKED: macFUSE not installed |
| Filesystem | Large upload/download with SHA-256 compare | TESTED (64 MB up, 32 MB down) |
| Filesystem | Multiple independent mounts; duplicate refused | TESTED |
| Filesystem | Occupied mount point refused | TESTED |
| Filesystem | Safe unmount refuses with pending writes; wait-then-unmount | TESTED |
| Reliability | Process supervision, PID files, no SIGKILL | TESTED |
| Reliability | Bounded retry 2/5/15/30/60 s, then stop | TESTED (unit + real server-down) |
| Reliability | Interrupted upload resumes after outage | TESTED |
| Reliability | Reattach to running mounts after an app crash | TESTED |
| Reliability | Network change and sleep/wake reconnect | IMPLEMENTED (shares the tested retry path; not exercised with a real network drop) |
| Reliability | Quit with pending uploads asks the user | IMPLEMENTED |
| Reliability | Single instance | IMPLEMENTED |
| Cache | Per-drive limits, min free space, live stats | TESTED |
| Cache | Safe clean (never dirty files, never while mounted, symlink-safe) | TESTED |
| Transfers | Real progress from `core/stats`, history from `core/transferred`, queue from `vfs/queue` | TESTED |
| Security | Keychain, encrypted config, 0600/0700 permissions | TESTED |
| Security | Redaction of logs/activity/diagnostics | TESTED |
| Security | No secrets in argv; minimal child env | TESTED |
| Data | SQLite migrations, corrupt-DB recovery (kept aside) | TESTED |
| Lifecycle | Launch at login (SMAppService) | IMPLEMENTED (requires the app in /Applications) |
| Release | App bundle, icon, ad-hoc signing, DMG | TESTED (built and verified) |
| Release | Developer ID signing, notarization | BLOCKED: no Developer ID credentials. `Scripts/notarize.sh` is ready |
| P2 | Client-side encryption, offline pinning, more providers | NOT STARTED |

## Known issues
- rclone on SFTP without a shell falls back to slower hashing. Expect this with chroot SFTP-only users; it is functionally fine.
- No per-file pause or cancel: rclone has none. Cancelling an upload of a dirty file would lose data, so the UI does not offer it.
- An app SIGKILLed while the NFS engine is mounted leaves rclone running; the next launch reattaches. If rclone itself is SIGKILLed, the NFS mount goes stale until `umount -f`. The app never sends SIGKILL.
- Screenshots and AppleScript quit could not run from the build agent (no screen-recording / automation permission), so the UI was only launch-checked.
