#!/usr/bin/env bash
# 70-backup.sh — schedule the snapshot of the hot tier onto the USB disk.
#
# The backup is the ONLY thing in this package that needs the USB disk. It is
# therefore scheduled separately and allowed to fail without touching CI.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/_lib.sh"
source "${HOST_ENV}"

need_root "$@"

PKG_ROOT="$(cd "${HERE}/.." && pwd)"

log "installing the backup service"
cat >/etc/systemd/system/oma-backup.service <<UNIT
[Unit]
Description=Snapshot Forgejo data and the mirror cache onto the USB disk
After=network-online.target forgejo.service
Wants=network-online.target
RequiresMountsFor=${USB_DISK}

[Service]
Type=oneshot
ExecStart=${PKG_ROOT}/backup/backup-to-usb.sh
Nice=10
IOSchedulingClass=idle
UNIT

cat >/etc/systemd/system/oma-backup.timer <<UNIT
[Unit]
Description=Back up the oma stack every ${BACKUP_INTERVAL_H} hours

[Timer]
OnBootSec=15min
OnUnitActiveSec=${BACKUP_INTERVAL_H}h
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now oma-backup.timer

if mountpoint -q "$USB_DISK"; then
  ok "backup timer enabled — ${USB_DISK} is mounted"
else
  systemctl enable --now oma-backup.timer >/dev/null 2>&1 || true
  warn "backup timer enabled — but ${USB_DISK} is not mounted right now"
  note "the backup skips itself while the disk is absent; CI is unaffected"
  note "mount it with: sudo mount ${USB_DISK}"
fi

# One run right now so the operator sees it work (or sees it skip cleanly).
log "running a backup now to verify"
bash "${PKG_ROOT}/backup/backup-to-usb.sh" || warn "the first backup did not complete"

systemctl list-timers --all 'oma-backup*' --no-pager | sed 's/^/  /' || true
