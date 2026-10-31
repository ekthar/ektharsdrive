# Install, uninstall, troubleshoot

## Install

1. Open the DMG and drag **Ekthar Drive** to Applications. Or build from source with `Scripts/build-app.sh`.
2. This build is ad-hoc signed and not notarized. On first open, right-click the app and choose **Open**, or allow it in **System Settings > Privacy & Security**.
3. Follow the setup wizard:
   - **rclone**: click **Install rclone**. It downloads the official build from rclone.org, verifies the SHA-256, and puts it in `~/Library/Application Support/EktharDrive/bin`. A Homebrew rclone works only with the NFS engine, because it is built without macFUSE support.
   - **macFUSE (optional)**: install it from [macfuse.github.io](https://macfuse.github.io) and approve it in System Settings > Privacy & Security. Without it, the built-in NFS engine mounts volumes in `~/Volumes`.
   - Connect Google ([guide](GOOGLE_OAUTH_SETUP.md)) and Oracle ([guide](ORACLE_SFTP_SETUP.md)).
4. Optional: **Settings > General > Launch at login** (works for the app in /Applications).

## Uninstall

1. Click **Unmount All** in the menu bar and wait for uploads to finish.
2. **Settings > Accounts > Disconnect** for each drive. This revokes the Google token and removes the trusted host key.
3. Quit, then delete the app and these folders:
   - `~/Library/Application Support/EktharDrive`
   - `~/Library/Caches/EktharDrive` (check that nothing is waiting to upload first)
   - `~/Library/Logs/EktharDrive`
4. In Keychain Access, delete items with the service `com.ekthar.drive`.
5. Optional: remove the `ekthar-drive` user and the `Match` block on the VM. The setup script left a backup of `sshd_config`.

## Troubleshooting

| Symptom | What to do |
|---|---|
| "rclone is not installed" | Settings > Advanced > Install rclone. |
| "This rclone build cannot mount" | Homebrew rclone + macFUSE engine. Install the official rclone, or choose Built-in NFS. |
| "Mount location is in use" | Something is already mounted there, or the folder contains files. Choose another location in Settings > General, or empty the folder. |
| "N uploads still pending" when unmounting | Use **Unmount When Uploads Finish**. Nothing is lost; pending files stay in the cache. |
| "Volume is busy" | An app has files open on the volume. Close them and retry. |
| Drive stuck "Reconnecting" | Check the network or the VM. After 5 attempts it stops; click Retry. |
| "Server identity changed" | See [ORACLE_SFTP_SETUP.md](ORACLE_SFTP_SETUP.md#if-the-host-key-changes). |
| Low disk warning | Lower cache limits in Cache, or free up space. rclone stops growing the cache below the "keep at least" threshold. |
| Anything else | Settings > Advanced > Export Diagnostics (redacted), and see `~/Library/Logs/EktharDrive/`. |
