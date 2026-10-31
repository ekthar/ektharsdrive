# Ekthar Drive

**Your storage. One native experience.**

A native macOS (SwiftUI) app that mounts your existing Google Drive and your Oracle Cloud VM as two separate Finder volumes. It uses [rclone](https://rclone.org) as the filesystem engine and talks to your storage directly. There is no Ekthar Drive server, database server or subscription.

| Volume | Backend | Auth | Default mount |
|---|---|---|---|
| Google Drive | rclone `drive` (scope `drive`) | OAuth 2.0 in your browser | `/Volumes/Google Drive` (macFUSE) or `~/Volumes/Google Drive` (NFS) |
| Oracle Drive | rclone `sftp` | SSH key + verified host key | `/Volumes/Oracle Drive` or `~/Volumes/Oracle Drive` |

Each drive has its own rclone process, mount point, cache, control socket, retry state and health.

## Status

See [DEVELOPMENT_LOG.md](DEVELOPMENT_LOG.md) for the per-requirement status (IMPLEMENTED / TESTED / BLOCKED). In short:

- The Oracle/SFTP path is tested end to end against a real SFTP server and a real macOS mount. That covers read, write, rename, move, delete, Unicode names, 64 MB SHA-256 round trips, interrupted upload, reconnect, safe unmount and host-key mismatch.
- Google Drive is implemented on the same engine, but it has **not been tested against a real Google account**, because that needs your sign-in.
- The macFUSE engine is implemented, but it is **untested on this machine**, because macFUSE is not installed. The built-in NFS engine (`rclone nfsmount`) is what was tested.

This is not yet production-ready. The remaining gaps are listed in the development log.

## Quick start

```bash
Scripts/build-app.sh                 # builds build/Ekthar Drive.app (ad-hoc signed)
open "build/Ekthar Drive.app"        # first launch opens the setup wizard
Scripts/make-dmg.sh                  # optional: dist/EktharDrive-1.0.0.dmg
```

Requirements: macOS 14+, Xcode 16+ / Swift 6 toolchain. rclone is installed from inside the app (Settings > Advanced > Install rclone) or from rclone.org. macFUSE is optional.

Guides: [Install](Documentation/INSTALL.md) · [Google OAuth](Documentation/GOOGLE_OAUTH_SETUP.md) · [Oracle SFTP](Documentation/ORACLE_SFTP_SETUP.md) · [Architecture](ARCHITECTURE.md) · [Security](SECURITY.md) · [Testing](TESTING.md)
