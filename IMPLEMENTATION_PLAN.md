# Implementation plan

Order followed, highest priority first (P0 → P2). Status lives in [DEVELOPMENT_LOG.md](DEVELOPMENT_LOG.md).

| Phase | Work | Result |
|---|---|---|
| A. Inspection | macOS 27.2 arm64, Xcode 27 beta / Swift 6.4, 35 GB free, Homebrew present; rclone, macFUSE absent | Done |
| B. Engine prototype | Official rclone 1.75.2 in scratch; validated every flag in the brief; proved `nfsmount` works without macFUSE or root; rc over Unix socket; config encryption via env; SFTP host-key mismatch refusal | Done |
| C. Core engine | Models, typed errors and classifier, ProcessRunner, ProcessSupervisor, RcClient, MountManager, CacheManager, TransferTracker, SQLite, Keychain, HostKeyVerifier, providers, DriveManager | Done, tested |
| D. App | SwiftUI shell, sidebar, dashboard, drive detail pages, account sheets, Transfers, Cache, Activity, Settings, About, setup wizard, menu bar | Done, built, launched |
| E. Storage management | Cache stats + safe clean, transfer history, activity log, reconnect and backoff, safe unmount, sleep/wake hook, adoption after a crash | Done, tested (except sleep/wake) |
| F. Testing | 46 unit tests + 9 real-mount integration tests | Passing |
| G. Release | `build-app.sh`, `make-dmg.sh`, `notarize.sh`, icon, docs | App + DMG built (ad-hoc signed, not notarized) |

## Next (not started)

1. Run the Google flow against the real account and fix anything it reveals.
2. Install macFUSE and run the integration suite with `mountEngine = .macFUSE`.
3. Developer ID signing + notarization (needs an Apple Developer account).
4. P2: an rclone `crypt` layer for client-side encryption, offline pinning, more providers.
