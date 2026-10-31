# Architecture

```
SwiftUI app (EktharDrive target)            Core library (EktharDriveCore target)
 RootView / Dashboard / Drive detail   ──▶   DriveManager  (@MainActor @Observable, single source of truth)
 Transfers / Cache / Activity / Settings       ├─ MountManager ── MountCommandBuilder (pure argv builder)
 Setup wizard / MenuBarExtra                   ├─ ProcessSupervisor (actor) ── rclone mount | nfsmount (one per drive)
 AppDelegate: single instance, safe quit,      ├─ RcClient ── HTTP over Unix socket ── rclone rc (vfs/stats, core/stats, …)
   sleep/wake, login item                      ├─ TransferTracker (rclone stats ─▶ Transfer records)
                                               ├─ CacheManager (live rclone stats, disk scan, safe clean)
                                               ├─ GoogleDriveProvider / OracleSFTPProvider ── RcloneService (one-shot rclone)
                                               ├─ HostKeyVerifier (ssh-keyscan + app known_hosts)
                                               ├─ KeychainStore (SecItem)   AppDatabase (SQLite, migrations)
                                               └─ NetworkMonitor (NWPathMonitor)   DependencyChecker / RcloneInstaller
```

## Key decisions

| Decision | Why |
|---|---|
| Swift package with a library + executable, bundled by `Scripts/build-app.sh` | No hand-maintained `.xcodeproj`; the core is testable with `swift test`. |
| Two mount engines: **macFUSE** (`rclone mount`) and **built-in NFS** (`rclone nfsmount`) | macFUSE needs a system extension the user must approve. NFS needs nothing extra: rclone serves NFS on 127.0.0.1 and macOS mounts it. `Automatic` uses macFUSE when usable, else NFS. |
| NFS volumes live in `~/Volumes/<name>` | `/Volumes` is root-owned; macFUSE creates its own mount points there, NFS cannot. |
| Control via `--rc-addr unix://<0700 dir>/<id>.sock --rc-no-auth` | No TCP port is opened, and no password goes on a command line. Only this user can reach the socket. |
| rclone.conf is app-private, `0600` and encrypted (`RCLONE_ENCRYPT_V0`) | It holds the Google token. The random config password lives in the Keychain and reaches rclone only via the child's environment (`RCLONE_CONFIG_PASS`). |
| Secrets travel via env, never argv | `RCLONE_DRIVE_CLIENT_SECRET`, `RCLONE_SFTP_KEY_FILE_PASS` (obscured). Child processes get a minimal environment (`SafeEnvironment`). |
| rclone's VFS cache is the only content cache | `--vfs-cache-mode full` with per-drive size and age limits plus `--vfs-cache-min-free-space`. The app measures it and cleans it only when the drive is unmounted, and never touches files marked `Dirty`. |
| No polling while idle | The poll loop only queries mounted drives: every 1 s with transfers active, else every 5 s. Capacity is refreshed every 5 min. Network changes come from NWPathMonitor. |
| PID files + process adoption | If the app quits or crashes with volumes mounted, rclone keeps running. The next launch reads the PID files, checks the process argv via `KERN_PROCARGS2`, and reattaches instead of mounting twice. |

## Mount lifecycle (per drive)

`unmounted → mounting → mounted → (waitingForUploads) → unmounting → unmounted`.

On an unexpected exit or a startup failure, a retryable error moves the drive to `retrying(attempt)` with backoff 2/5/15/30/60 s, capped by the drive's `maxRetryAttempts`, and then to `failed`. Security, auth and config errors go straight to `failed` and never retry. While offline the drive waits for NWPathMonitor instead of burning retries. Wake from sleep triggers a check.

## Safe unmount

1. `vfs/stats` gives `uploadsInProgress + uploadsQueued`. If that is above 0, the unmount is refused with `.pendingWrites(n)` unless the user chose "Unmount When Uploads Finish". In that case the app waits, and cancelling cancels only the wait.
2. If the process is alive but not answering, the app refuses, because it cannot prove nothing is pending.
3. The app runs `/sbin/umount <path>`. A "busy" result is reported and never forced.
4. rclone then exits by itself. If it lingers, it gets SIGTERM. SIGKILL is never sent.

Quitting with pending uploads offers three choices: wait, keep the volumes running in the background (they are reattached on the next launch), or cancel.

## Data stored

| Where | What |
|---|---|
| `~/Library/Application Support/EktharDrive/ekthar-drive.sqlite` (0600) | drives, transfers, activity, settings, SFTP host/user/key path. No secrets. |
| `…/rclone.conf` (0600, encrypted) | rclone remotes including the Google OAuth token |
| `…/known_hosts` (0600) | host keys you verified |
| `…/run/` (0700) | control sockets, PID files, single-instance lock |
| `~/Library/Caches/EktharDrive/<drive>/` (0700) | rclone VFS cache |
| `~/Library/Logs/EktharDrive/<drive>.log` (0600) | redacted rclone output, rotated at 5 MB |
| Keychain service `com.ekthar.drive` | config password, optional Google client secret, optional SSH key passphrase |
