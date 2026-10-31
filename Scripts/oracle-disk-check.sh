#!/bin/bash
# Real disk capacity of the Oracle storage directory, over SSH with an admin account (not the SFTP-only user).
#   Scripts/oracle-disk-check.sh ubuntu@<vm-ip> [/srv/ekthar-drive/files]
# Ekthar Drive itself reads capacity through SFTP (statvfs) via `rclone about`; this is a manual cross-check.
set -euo pipefail
TARGET="${1:?usage: oracle-disk-check.sh user@host [directory]}"
DIR="${2:-/srv/ekthar-drive/files}"
ssh -o StrictHostKeyChecking=yes "$TARGET" -- df -h --output=source,size,used,avail,pcent,target "$DIR"
