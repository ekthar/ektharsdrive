#!/bin/bash
# OPTIONAL. Run this yourself ON THE ORACLE VM (as a sudo-capable admin user). Ekthar Drive never runs it.
#
# Creates a dedicated SFTP-only user "ekthar-drive", jailed (chroot) to /srv/ekthar-drive, with a writable
# /srv/ekthar-drive/files directory. Inside the jail the client sees that directory as "/files", so in
# Ekthar Drive set Remote directory = /files.
#
#   sudo bash oracle-server-setup.sh "ssh-ed25519 AAAA... you@mac"
#
# Safety:
# - does not change PasswordAuthentication or root login for anyone else
# - backs up sshd_config and validates with `sshd -t` before reloading; restores the backup on failure
# - refuses to run twice over an existing Match block
set -euo pipefail

PUBKEY="${1:-}"
USER_NAME="ekthar-drive"
JAIL="/srv/ekthar-drive"
SSHD="/etc/ssh/sshd_config"

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }
[[ "$PUBKEY" == ssh-* ]] || { echo "Pass your Mac's PUBLIC key (contents of ~/.ssh/id_ed25519.pub) as the first argument."; exit 1; }

if grep -q "Match User $USER_NAME" "$SSHD"; then
  echo "$SSHD already has a 'Match User $USER_NAME' block. Not changing it."
else
  cp -p "$SSHD" "$SSHD.ekthar-backup-$(date +%Y%m%d%H%M%S)"
fi

if ! id "$USER_NAME" >/dev/null 2>&1; then
  useradd --system --no-create-home --home-dir / --shell /usr/sbin/nologin "$USER_NAME"
fi

# Chroot requirements: every path component up to the jail is root-owned and not group/world writable.
mkdir -p "$JAIL/files"
chown root:root /srv "$JAIL"
chmod 755 /srv "$JAIL"
chown "$USER_NAME:$USER_NAME" "$JAIL/files"
chmod 750 "$JAIL/files"

# Keys live outside the jail, root-owned, so the user cannot change them.
install -d -m 755 -o root -g root /etc/ssh/authorized_keys
echo "$PUBKEY" > "/etc/ssh/authorized_keys/$USER_NAME"
chmod 644 "/etc/ssh/authorized_keys/$USER_NAME"

if ! grep -q "Match User $USER_NAME" "$SSHD"; then
  BACKUP="$(ls -t "$SSHD".ekthar-backup-* | head -1)"
  cat >> "$SSHD" <<EOF

# Added by Ekthar Drive setup script
Match User $USER_NAME
    AuthorizedKeysFile /etc/ssh/authorized_keys/%u
    PasswordAuthentication no
    ChrootDirectory $JAIL
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
EOF
  if ! sshd -t; then
    echo "sshd_config validation failed; restoring backup."
    cp -p "$BACKUP" "$SSHD"
    exit 1
  fi
fi

systemctl reload ssh 2>/dev/null || systemctl reload sshd
echo
echo "Done. In Ekthar Drive use: user=$USER_NAME  remote directory=/files"
echo "Host key fingerprint to compare in the app:"
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
echo "Disk space for the storage directory:"
df -h "$JAIL/files"
