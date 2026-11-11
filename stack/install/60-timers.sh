#!/usr/bin/env bash
# 60-timers.sh — schedule the mirror, the issue snapshot and the healthcheck.
#
# All three run on systemd timers, so they survive reboots and laptop sleeps.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/_lib.sh"
source "${HOST_ENV}"

need_root "$@"

PKG_ROOT="${HERE}/.."
install -d -m 0755 "$PKG_ROOT"

# ---------------------------------------------------------------------------
# mirror sync
# ---------------------------------------------------------------------------
log "installing the mirror timer"
cat >/etc/systemd/system/oma-mirror-sync.service <<UNIT
[Unit]
Description=Mirror GitHub repositories into Forgejo (one direction)
After=network-online.target forgejo.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${PKG_ROOT}/mirror/mirror-sync.sh
UNIT

cat >/etc/systemd/system/oma-mirror-sync.timer <<UNIT
[Unit]
Description=Run the GitHub -> Forgejo mirror every ${MIRROR_INTERVAL_MIN} minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=${MIRROR_INTERVAL_MIN}min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

# ---------------------------------------------------------------------------
# issue snapshot
# ---------------------------------------------------------------------------
log "installing the issue-snapshot timer"
cat >/etc/systemd/system/oma-issue-snapshot.service <<UNIT
[Unit]
Description=Publish a read-only GitHub issue snapshot into Forgejo
After=network-online.target forgejo.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${PKG_ROOT}/mirror/issue-snapshot.sh
UNIT

cat >/etc/systemd/system/oma-issue-snapshot.timer <<UNIT
[Unit]
Description=Snapshot GitHub issues every ${ISSUE_SNAPSHOT_INTERVAL_MIN} minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=${ISSUE_SNAPSHOT_INTERVAL_MIN}min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

# ---------------------------------------------------------------------------
# healthcheck
# ---------------------------------------------------------------------------
log "installing the healthcheck timer"
cat >/etc/systemd/system/oma-healthcheck.service <<UNIT
[Unit]
Description=Check that the oma stack is healthy
After=network-online.target

[Service]
Type=oneshot
ExecStart=${PKG_ROOT}/../verify/healthcheck.sh
UNIT

cat >/etc/systemd/system/oma-healthcheck.timer <<UNIT
[Unit]
Description=Healthcheck the oma stack every ${HEALTHCHECK_INTERVAL_MIN} minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=${HEALTHCHECK_INTERVAL_MIN}min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now oma-mirror-sync.timer
systemctl enable --now oma-issue-snapshot.timer
systemctl enable --now oma-healthcheck.timer
ok "three timers enabled (mirror, issue snapshot, healthcheck) — the backup timer is installed by step 70"

systemctl list-timers --all 'oma-*' --no-pager | sed 's/^/  /' || true
