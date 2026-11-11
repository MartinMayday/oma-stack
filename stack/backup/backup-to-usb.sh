#!/usr/bin/env bash
# backup/backup-to-usb.sh — snapshot the hot tier onto the 4 TB USB SATA disk.
#
# WHAT IS BACKED UP
#   ${BOOT_DATA}/data/forgejo.db   the Forgejo database (SQLite, hot copy)
#   ${REPO_ROOT}                   the mirrored git repositories
#   ${ACTIONS_LOG}                 CI job logs
#   ${ACTIONS_ARTIFACTS}           CI artifacts
#   /etc/forgejo/app.ini           the server config (contains secrets -> mode 0600)
#   ${MIRROR_CACHE}                the bare git cache used by the mirror
#
# WHAT IS NOT
#   Docker data-root (re-pullable), runner work dirs (ephemeral), logs.
#
# WHY THE DATABASE IS COPIED WITH sqlite3 .backup AND NOT cp
#   Forgejo writes to SQLite while the service is running. A plain cp of a live
#   .db file can capture a torn page. `sqlite3 .backup` takes a read lock and
#   writes a transactionally consistent copy without stopping Forgejo.
#
# THE USB DISK IS NOT A DEPENDENCY
#   If the disk is not mounted the script exits 0 with a warning. CI, the
#   mirror and the tracker keep running; only the backup is skipped.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../install/_lib.sh"
source "${HOST_ENV}"

DB_PATH="${BOOT_DATA}/data/forgejo.db"
CONFIG_FILE="/etc/forgejo/app.ini"

# --- the paths the server actually uses -------------------------------------
# host.env is the intent; app.ini is the truth (it is what Forgejo was
# actually started with). They differ when USB_HOLDS_ACTIONS=1 moves the
# Actions storage onto the USB disk. Reading app.ini means the backup always
# archives the live paths, not the configured defaults.
ini_get() { # ini_get <section> <key> <default>
  local section="$1" key="$2" def="$3" value=""
  if [[ -f "$CONFIG_FILE" ]]; then
    value=$(awk -v s="[${section}]" -v k="${key}" '
      $0 == s            { inside = 1; next }
      /^\[/              { inside = 0 }
      inside && index($0, "=") {
        split($0, a, "=")
        gsub(/^[ \t]+|[ \t]+$/, "", a[1])
        gsub(/^[ \t]+|[ \t]+$/, "", a[2])
        if (a[1] == k) { print a[2]; exit }
      }' "$CONFIG_FILE")
  fi
  printf '%s' "${value:-$def}"
}

REPO_ROOT_EFF="$(ini_get repository ROOT "$REPO_ROOT")"
ACTIONS_LOG_EFF="$(ini_get storage.actions_log PATH "$ACTIONS_LOG")"
ACTIONS_ARTIFACTS_EFF="$(ini_get storage.actions_artifacts PATH "$ACTIONS_ARTIFACTS")"

# --- preconditions ---------------------------------------------------------
if ! mountpoint -q "$USB_DISK"; then
  warn "${USB_DISK} is not mounted — skipping the backup (nothing else is affected)"
  exit 0
fi

if [[ ! -d "$BOOT_DATA" ]]; then
  die "${BOOT_DATA} does not exist — nothing to back up"
fi

install -d -m 0700 "$BACKUP_ROOT"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="${BACKUP_ROOT}/${STAMP}"
PART="${DEST}.partial"

# A stale .partial from a killed run would otherwise accumulate.
rm -rf "$PART"
install -d -m 0700 "$PART"

log "backup -> ${DEST}"

# --- 1. the database -------------------------------------------------------
if [[ -f "$DB_PATH" ]]; then
  if have sqlite3; then
    sqlite3 "$DB_PATH" ".backup '${PART}/forgejo.db'"
    ok "database copied consistently ($(du -h "${PART}/forgejo.db" | cut -f1))"
  else
    # No sqlite3 CLI: fall back to a file copy. Less safe, but better than
    # no backup at all. The next successful run replaces it.
    cp -a "$DB_PATH" "${PART}/forgejo.db"
    warn "sqlite3 CLI missing — copied the live database file (may be inconsistent)"
  fi
else
  warn "no database at ${DB_PATH} — skipping the DB copy"
fi

# --- 2. repositories, logs, artifacts, mirror cache ------------------------
archive_tree() {
  local label="$1" path="$2" archive="$3"
  [[ -d "$path" ]] || { warn "${label} missing (${path}) — skipped"; return 0; }
  tar -C "$(dirname "$path")" -czf "${PART}/${archive}" "$(basename "$path")"
  ok "${label} archived ($(du -h "${PART}/${archive}" | cut -f1))"
}

archive_tree "repositories"  "$REPO_ROOT_EFF"        "forgejo-repositories.tar.gz"
archive_tree "actions log"   "$ACTIONS_LOG_EFF"       "actions-log.tar.gz"
archive_tree "actions build" "$ACTIONS_ARTIFACTS_EFF" "actions-artifacts.tar.gz"
archive_tree "mirror cache"  "$MIRROR_CACHE"          "mirror-cache.tar.gz"

# --- 3. server config ------------------------------------------------------
if [[ -f "$CONFIG_FILE" ]]; then
  cp -a "$CONFIG_FILE" "${PART}/app.ini"
  chmod 0600 "${PART}/app.ini"
  ok "server config copied"
fi

# --- 4. manifest + restore helper ------------------------------------------
cat >"${PART}/MANIFEST.txt" <<EOF
oma-stack backup
created      : $(date -u +%Y-%m-%dT%H:%M:%SZ)
host         : $(hostname)
boot data    : ${BOOT_DATA}
forgejo db   : ${DB_PATH}
repositories : ${REPO_ROOT_EFF}
actions log  : ${ACTIONS_LOG_EFF}
artifacts    : ${ACTIONS_ARTIFACTS_EFF}
restore with : sudo bash ${DEST}/RESTORE.sh
EOF

cat >"${PART}/RESTORE.sh" <<'RESTORE'
#!/usr/bin/env bash
# Restore this snapshot over a stopped Forgejo.
#
#   sudo systemctl stop forgejo.service
#   sudo bash RESTORE.sh
#   sudo systemctl start forgejo.service
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT_DATA="${BOOT_DATA:-/var/lib/forgejo}"

[[ $EUID -eq 0 ]] || { echo "must run as root"; exit 1; }

systemctl is-active --quiet forgejo.service && {
  echo "forgejo is still running — stop it first: systemctl stop forgejo.service"
  exit 1
}

install -d -m 0755 "${BOOT_DATA}/data"

if [[ -f "${HERE}/forgejo.db" ]]; then
  cp -a "${HERE}/forgejo.db" "${BOOT_DATA}/data/forgejo.db"
  echo "database restored"
fi

for a in forgejo-repositories actions-log actions-artifacts mirror-cache; do
  [[ -f "${HERE}/${a}.tar.gz" ]] || continue
  tar -C "${BOOT_DATA}" -xzf "${HERE}/${a}.tar.gz"
  echo "${a} restored"
done

if [[ -f "${HERE}/app.ini" ]]; then
  cp -a "${HERE}/app.ini" /etc/forgejo/app.ini
  chmod 0660 /etc/forgejo/app.ini
  echo "server config restored"
fi

chown -R forgejo:forgejo "${BOOT_DATA}" 2>/dev/null || true
echo "done — start forgejo: systemctl start forgejo.service"
RESTORE
chmod 0700 "${PART}/RESTORE.sh"

# --- 5. publish atomically -------------------------------------------------
mv "$PART" "$DEST"
ok "snapshot published to ${DEST}"

# --- 6. prune --------------------------------------------------------------
KEEP="${BACKUP_RETENTION:-7}"
mapfile -t OLD < <(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d -name '20*' -printf '%f\n' | sort -r | tail -n "+$((KEEP + 1))")
if (( ${#OLD[@]} > 0 )); then
  for d in "${OLD[@]}"; do
    rm -rf "${BACKUP_ROOT:?}/${d}"
    log "pruned old snapshot ${d}"
  done
fi

date -u +%Y-%m-%dT%H:%M:%SZ >"${BACKUP_ROOT}/.last-backup"
ok "backup complete — $(du -sh "$DEST" | cut -f1), $(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d -name '20*' | wc -l) snapshot(s) kept"
