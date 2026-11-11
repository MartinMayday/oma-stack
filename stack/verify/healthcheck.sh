#!/usr/bin/env bash
# verify/healthcheck.sh — is the oma stack actually healthy?
#
# Run by systemd every ${HEALTHCHECK_INTERVAL_MIN} minutes.
# Exits non-zero when something is wrong, so systemd records a failed unit.
# Writes a one-line status to /var/log/oma-stack-health.log.
#
# Three states:
#   PASS  everything is fine
#   WARN  degraded but not fatal (e.g. the optional USB backup disk is absent)
#   FAIL  something that breaks CI or data safety

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../install/_lib.sh"
source "${HOST_ENV}"

FORGEJO_URL="${FORGEJO_URL:-http://127.0.0.1:3000}"
STATUS_FILE="/var/log/oma-stack-health.log"

PROBLEMS=0
WARNINGS=0
RESULTS=()

check() {
  local name="$1" state="$2" detail="$3"
  case "$state" in
    yes) RESULTS+=("PASS  ${name}: ${detail}") ;;
    warn) RESULTS+=("WARN  ${name}: ${detail}"); WARNINGS=$((WARNINGS+1)) ;;
    *)   RESULTS+=("FAIL  ${name}: ${detail}"); PROBLEMS=$((PROBLEMS+1)) ;;
  esac
}

# --- forgejo ---------------------------------------------------------------
if systemctl is-active --quiet forgejo.service 2>/dev/null; then
  check "forgejo.service" yes "active"
else
  check "forgejo.service" no "not active"
fi

if curl -fsS -o /dev/null --max-time 5 "${FORGEJO_URL}/api/v1/version"; then
  check "forgejo.http" yes "200 on ${FORGEJO_URL}"
else
  check "forgejo.http" no "no answer on ${FORGEJO_URL}"
fi

# --- storage: internal SSD (the hot tier, must have room) --------------------
BOOT_PCT=$(df -P "${BOOT_DATA:-/}" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')
BOOT_PCT="${BOOT_PCT:-0}"
if (( BOOT_PCT >= 95 )); then
  check "storage.internal" no "internal SSD ${BOOT_PCT}% full — refusing to run CI out of space"
elif (( BOOT_PCT >= 85 )); then
  check "storage.internal" warn "internal SSD ${BOOT_PCT}% full"
else
  check "storage.internal" yes "internal SSD ${BOOT_PCT}% used"
fi

# --- storage: USB SATA (backups only — advisory) ----------------------------
if mountpoint -q "$USB_DISK"; then
  USB_PCT=$(df -P "$USB_DISK" | awk 'NR==2 {gsub("%","",$5); print $5}')
  if (( USB_PCT >= 95 )); then
    check "storage.usb" warn "mounted but ${USB_PCT}% full — backups will start failing"
  else
    check "storage.usb" yes "mounted, ${USB_PCT}% used"
  fi
else
  check "storage.usb" warn "${USB_DISK} not mounted — CI keeps running, backups are skipped"
fi

# --- runners ---------------------------------------------------------------
if systemctl is-active --quiet forgejo-runner.service 2>/dev/null; then
  check "forgejo-runner" yes "active"
else
  check "forgejo-runner" no "not active (Forgejo jobs will queue)"
fi

if [[ -x "${GITHUB_RUNNER_DIR}/svc.sh" ]]; then
  if "${GITHUB_RUNNER_DIR}/svc.sh" status >/dev/null 2>&1; then
    check "github-runner" yes "service running"
  else
    check "github-runner" no "installed but not running"
  fi
fi

# --- mirror freshness ------------------------------------------------------
LAST_SYNC="${MIRROR_CACHE}/.last-sync"
if [[ -f "$LAST_SYNC" ]]; then
  AGE_MIN=$(( ( $(date +%s) - $(stat -c %Y "$LAST_SYNC") ) / 60 ))
  LIMIT=$(( MIRROR_INTERVAL_MIN * 3 ))
  if (( AGE_MIN > LIMIT )); then
    check "mirror.freshness" no "last sync ${AGE_MIN} min ago (limit ${LIMIT})"
  else
    check "mirror.freshness" yes "last sync ${AGE_MIN} min ago"
  fi
else
  check "mirror.freshness" no "never synced"
fi

# --- backup freshness ------------------------------------------------------
LAST_BACKUP="${BACKUP_ROOT}/.last-backup"
if ! mountpoint -q "$USB_DISK"; then
  check "backup.freshness" warn "USB not mounted — no backups being written"
elif [[ -f "$LAST_BACKUP" ]]; then
  AGE_H=$(( ( $(date +%s) - $(stat -c %Y "$LAST_BACKUP") ) / 3600 ))
  LIMIT_H=$(( BACKUP_INTERVAL_H * 3 ))
  if (( AGE_H > LIMIT_H )); then
    check "backup.freshness" no "last backup ${AGE_H} h ago (limit ${LIMIT_H} h)"
  else
    check "backup.freshness" yes "last backup ${AGE_H} h ago"
  fi
else
  check "backup.freshness" no "never backed up"
fi

# --- github reachability ---------------------------------------------------
if curl -fsS -o /dev/null --max-time 8 https://github.com; then
  check "network.github" yes "reachable"
else
  check "network.github" no "github.com unreachable"
fi

# --- report ----------------------------------------------------------------
STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
  echo "[${STAMP}] $(printf '%s' "${RESULTS[@]}" | grep -c '^PASS') pass, ${WARNINGS} warn, ${PROBLEMS} fail"
  printf '%s\n' "${RESULTS[@]}"
  echo
} >>"$STATUS_FILE"

printf '%s\n' "${RESULTS[@]}"
if (( PROBLEMS > 0 )); then
  echo
  warn "${PROBLEMS} problem(s) found — see $STATUS_FILE"
  exit 1
fi
if (( WARNINGS > 0 )); then
  echo
  warn "${WARNINGS} warning(s) — see $STATUS_FILE"
fi
ok "all checks passed"
