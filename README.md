# Ekthar Drive

**Your storage. One native experience.**

A native macOS (SwiftUI) app that mounts your existing Google Drive and your Oracle Cloud VM as two separate Finder volumes. It uses [rclone](https://rclone.org) as the filesystem engine and talks to your storage directly. There is no Ekthar Drive server, database server or subscription.

| Volume | Backend | Auth | Default mount |
|---|---|---|---|
| Google Drive | rclone `drive` (scope `drive`) | OAuth 2.0 in your browser | `/Volumes/Google Drive` (macFUSE) or `~/Volumes/Google Drive` (NFS) |
| Oracle Drive | rclone `sftp` | SSH key + verified host key | `/Volumes/Oracle Drive` or `~/Volumes/Oracle Drive` |
| Vault (optional) | rclone `crypt` inside Google Drive | Password in Keychain | `~/Volumes/Vault` |

Each drive has its own rclone process, mount point, cache, control socket, retry state and health.

## Download

Get the latest DMG from [Releases](https://github.com/ekthar/ektharsdrive/releases). It is signed with a local certificate, not notarized, so the first time right-click the app and choose **Open**.

## Features

- **Finder volumes** through a built-in NFS engine (`rclone serve nfs` + `mount_nfs`), no kernel extension needed. macFUSE is optional.
- **Browser:** icons and list, Quick Look, real previews for images, PDFs and videos, drag and drop of files and folders both ways, share links, Copy to another drive, Starred and Trash.
- **Find:** drive-wide search through Google's own index, Recents, smart folders, duplicate finder, space map.
- **Speed:** Keep Offline folders, read-ahead of the selected file, preloaded folder listings, Google rate guard.
- **Transfers:** pause, resume or start a queued upload now, pause all, cancel a copy, speed limit.
- **Vault:** an encrypted folder in Google Drive with its own volume. Names and contents are encrypted on the Mac.
- **Menu bar:** status, and a drop zone that appears when you drag files toward the menu bar.
- **Reliability:** watchdog restart, keep-awake while uploading, low-disk guard, crash reports, safe eject that never drops pending uploads.

## Status

See [DEVELOPMENT_LOG.md](DEVELOPMENT_LOG.md) for the per-requirement status (IMPLEMENTED / TESTED / BLOCKED). In short:

- The Oracle/SFTP path is tested end to end against a real SFTP server and a real macOS mount: read, write, rename, move, delete, Unicode names, 64 MB SHA-256 round trips, interrupted upload, reconnect, safe unmount, host-key mismatch, upload queue controls and the vault's encryption.
- Google Drive is used daily against a real account (5.5 TB). Search, Recents, Duplicates and Space have opt-in live tests (`EKTHAR_LIVE_GOOGLE_SOCKET`).
- The macFUSE engine is implemented, but on the test machine its File System Extension would not stay enabled, so the app falls back to NFS.
- Not available without a paid Apple Developer account: an FSKit file system extension and notarization.

## Quick start

```bash
Scripts/build-app.sh                 # builds build/Ekthar Drive.app
open "build/Ekthar Drive.app"        # first launch opens the setup wizard
Scripts/make-dmg.sh                  # optional: dist/EktharDrive-<version>.dmg
```

Requirements: macOS 14+, Xcode 16+ / Swift 6 toolchain. rclone is installed from inside the app (Settings > Advanced > Install rclone) or from rclone.org. macFUSE is optional.

Guides: [Install](Documentation/INSTALL.md) · [Google OAuth](Documentation/GOOGLE_OAUTH_SETUP.md) · [Oracle SFTP](Documentation/ORACLE_SFTP_SETUP.md) · [Architecture](ARCHITECTURE.md) · [Security](SECURITY.md) · [Testing](TESTING.md)
