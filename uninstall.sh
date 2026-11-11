#!/usr/bin/env bash
# uninstall.sh — take the stack back off this machine.
#
#   sudo ./uninstall.sh              stop the services, keep the data
#   sudo ./uninstall.sh --purge      also delete the data and the config
#
# What it never touches: GitHub.  The mirror only ever reads from GitHub, so
# there is nothing to undo there.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/stack/install/_lib.sh"
source "${HOST_ENV}"

PURGE=0
while (( $# )); do
  case "$1" in
    --purge) PURGE=1; shift ;;
    *)       die "unknown option: $1" ;;
  esac
done

need_root

UNITS=(
  oma-agent-bridge.service
  oma-openbot.service
  oma-backup.timer
  oma-backup.service
  oma-healthcheck.timer
  oma-healthcheck.service
  oma-issue-snapshot.timer
  oma-issue-snapshot.service
  oma-mirror-sync.timer
  oma-mirror-sync.service
  forgejo-runner.service
  forgejo.service
)

log "stopping the services"
for unit in "${UNITS[@]}"; do
  if systemctl list-unit-files "${unit}" >/dev/null 2>&1; then
    systemctl disable --now "${unit}" >/dev/null 2>&1 && ok "stopped ${unit}" || warn "could not stop ${unit}"
  fi
done

# The GitHub Actions runner installs itself as a service of its own.
if [[ -x "${GITHUB_RUNNER_DIR:-/opt/actions-runner}/svc.sh" ]]; then
  "${GITHUB_RUNNER_DIR}/svc.sh" uninstall "${GITHUB_RUNNER_NAME:-macbook-forge}" >/dev/null 2>&1 \
    && ok "removed the GitHub runner service" || warn "could not remove the GitHub runner service"
fi

log "removing the units"
for unit in "${UNITS[@]}"; do
  rm -f "/etc/systemd/system/${unit}"
done
rm -f /etc/logrotate.d/oma-stack
rm -f /etc/systemd/logind.conf.d/00-oma-stack.conf
systemctl daemon-reload
ok "units removed"

if (( PURGE )); then
  log "removing the data"
  if have docker; then
    docker rm -f oma-openbot >/dev/null 2>&1 || true
    docker volume rm "${OPENBOT_VOLUME:-oma-openbot-data}" >/dev/null 2>&1 || true
  fi
  rm -rf "${BOOT_DATA:-/var/lib/forgejo}"
  rm -rf "${HANDOFF_ROOT:-/var/lib/oma-stack/handoff}"
  rm -rf "${CRED_DIR:-/etc/oma-stack}"
  rm -rf "${GITHUB_RUNNER_DIR:-/opt/actions-runner}"
  rm -f /etc/forgejo/app.ini
  ok "data removed"
  note "the USB backups were left alone: ${BACKUP_ROOT:-/mnt/usb/backups}"
else
  note "the data was kept:"
  note "  ${BOOT_DATA:-/var/lib/forgejo}   Forgejo, repositories, actions, mirror cache"
  note "  ${CRED_DIR:-/etc/oma-stack}      configuration and secrets"
  note "  ${HANDOFF_ROOT:-/var/lib/oma-stack/handoff}  the handoff queue"
  note ""
  note "to remove them as well:  sudo ${HERE}/uninstall.sh --purge"
fi

ok "uninstalled"
