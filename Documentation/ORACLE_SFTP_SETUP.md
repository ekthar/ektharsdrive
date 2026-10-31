# Oracle Cloud VM setup (SFTP)

Ekthar Drive never changes your server. These steps are run by you.

## 1. Key on your Mac

```bash
ls ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -C "ekthar-drive"
```

At "Enter file in which to save the key", just press Enter.

## 2. Dedicated SFTP-only user on the VM

Copy `Scripts/oracle-server-setup.sh` to the VM and run it with your **public** key:

```bash
scp Scripts/oracle-server-setup.sh ubuntu@<vm-ip>:
ssh ubuntu@<vm-ip> 'sudo bash oracle-server-setup.sh "'"$(cat ~/.ssh/id_ed25519.pub)"'"'
```

What it does:

- creates user `ekthar-drive` with no shell (`internal-sftp` only), jailed (chroot) to `/srv/ekthar-drive`;
- sets the chroot ownership OpenSSH requires: `/srv` and `/srv/ekthar-drive` are `root:root 755`, and the writable `/srv/ekthar-drive/files` is owned by `ekthar-drive`;
- puts the key in a root-owned `/etc/ssh/authorized_keys/ekthar-drive`;
- adds a `Match User ekthar-drive` block with password auth off **for that user only**. It does not touch password login or root login for anyone else;
- backs up `sshd_config`, validates with `sshd -t`, and restores the backup if validation fails;
- prints the host key fingerprint and the real free space of the directory.

Because of the chroot, the directory appears to the SFTP user as **`/files`**. In Ekthar Drive set **Remote directory = `/files`**.

If you set the user up without a chroot, use the full path `/srv/ekthar-drive/files` instead (the app's default).

## 3. Network

The VM's VCN security list must allow TCP 22 (or your SSH port) from your IP. It already does on default Oracle images.

## 4. Connect in Ekthar Drive

1. **Oracle Drive > Configure**: enter the host/IP, port, user `ekthar-drive`, your private key `~/.ssh/id_ed25519`, and remote directory `/files`.
2. **Fetch Server Fingerprint.** On the VM, run `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` and check that the `SHA256:` value is identical. Then tick "I compared the fingerprint".
3. **Save and Test Connection.** The app lists the remote directory and reads real capacity. Success is only shown if both work.

## Capacity

The app shows the capacity the server's filesystem reports for that directory (SFTP `statvfs`, via `rclone about`). This is usually less than the "200 GB" boot volume you allocated, because the OS uses part of it, and Oracle images may not grow the root partition automatically. Cross-check with an admin account:

```bash
Scripts/oracle-disk-check.sh ubuntu@<vm-ip> /srv/ekthar-drive/files
```

## If the host key changes

Ekthar Drive stops with "Server identity changed" and will not connect or auto-mount. If you rebuilt the VM, run step 4.2 again to verify and trust the new key. If you did not, treat it as a possible interception and do not connect.
