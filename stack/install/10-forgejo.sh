#!/usr/bin/env bash
# 10-forgejo.sh — install and configure the Forgejo server.
#
# Storage map for this box:
#   /var/lib/forgejo        128 GB internal SSD -> DB, repos, actions logs/artifacts
#   /mnt/usb/backups        4 TB USB SATA         -> dated backups only
#   /mnt/sd/act-work        512 GB SD card        -> optional runner scratch
#
# Everything the server needs lives on the internal SSD. The USB disk is a
# backup target, not a runtime dependency: if it is unplugged, Forgejo keeps
# working and only the backups stop.
#
# Uses the Arch package when available (it ships its own systemd unit that
# already runs as User=forgejo with ProtectSystem=strict), and falls back to
# the upstream tarball on other distros.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/_lib.sh"
source "${HOST_ENV}"

need_root "$@"

# ---------------------------------------------------------------------------
# 1. Packages
# ---------------------------------------------------------------------------
log "installing packages"
pkg_install git curl jq sqlite openssl ca-certificates
ok "base packages present"

USE_PKG=0
if have pacman; then
  if pacman -S --needed --noconfirm forgejo >/dev/null 2>&1; then
    USE_PKG=1
    ok "forgejo installed from the Arch repo (packaged unit will be used)"
  else
    warn "forgejo not in the Arch repos — falling back to the upstream tarball"
  fi
fi

if (( USE_PKG == 0 )); then
  FORGEJO_VERSION="${FORGEJO_VERSION:-11.0.0}"
  log "installing Forgejo ${FORGEJO_VERSION} from upstream"
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/forgejo" \
    "https://codeberg.org/forgejo/forgejo/releases/download/v${FORGEJO_VERSION}/forgejo-${FORGEJO_VERSION}-linux-amd64"
  install -m 0755 "$tmp/forgejo" /usr/local/bin/forgejo
  rm -rf "$tmp"
  id -u forgejo >/dev/null 2>&1 || useradd --system --home-dir /var/lib/forgejo --shell /bin/bash forgejo
  install -d -o forgejo -g forgejo /etc/forgejo
  cat >/usr/lib/systemd/system/forgejo.service <<'UNIT'
[Unit]
Description=Forgejo
After=network.target

[Service]
User=forgejo
Group=forgejo
Type=simple
WorkingDirectory=~
RuntimeDirectory=forgejo
LogsDirectory=forgejo
StateDirectory=forgejo
ExecStart=/usr/local/bin/forgejo web -c /etc/forgejo/app.ini
Restart=always
RestartSec=2s
ReadWritePaths=/etc/forgejo/app.ini
ProtectSystem=strict
ProtectHome=true
PrivateUsers=true
PrivateTmp=true
NoNewPrivileges=True

[Install]
WantedBy=multi-user.target
UNIT
  ok "forgejo installed to /usr/local/bin/forgejo"
fi

# ---------------------------------------------------------------------------
# 2. Directories
# ---------------------------------------------------------------------------
log "creating directories"

# Opt-in: put the Actions logs and artifacts on the USB disk instead of the
# internal SSD. Off by default — it makes the USB disk a hard dependency of
# every CI run that produces an artifact.
if [[ "${USB_HOLDS_ACTIONS}" == "1" ]]; then
  ACTIONS_LOG="${USB_DISK}/forgejo/actions-log"
  ACTIONS_ARTIFACTS="${USB_DISK}/forgejo/actions-artifacts"
  log "Actions storage will live on the USB disk: ${ACTIONS_LOG}"
fi

install -d -o forgejo -g forgejo \
  "$BOOT_DATA" "$BOOT_DATA/data" "$REPO_ROOT" "$ACTIONS_LOG" "$ACTIONS_ARTIFACTS" \
  "$BOOT_DATA/data/attachments" "$BOOT_DATA/data/indexers" "$BOOT_DATA/data/tmp" \
  "$BOOT_DATA/custom" "$BOOT_DATA/log"

# The mirror cache is a bare git clone of every mirrored repo. It lives on
# the SSD because every sync touches it.
install -d -m 0755 "$MIRROR_CACHE"
ok "repositories at $REPO_ROOT (internal SSD)"

install -d -m 0700 "$CRED_DIR"
ok "directories ready"

# Where the runner will put job workspaces: the SD card when it is inserted,
# the internal SSD otherwise.
RUNNER_WORKDIR="$(runner_workdir)"
install -d -o "$RUNNER_USER" -g "$RUNNER_USER" "$RUNNER_WORKDIR" 2>/dev/null \
  || install -d "$RUNNER_WORKDIR"
if [[ "$RUNNER_WORKDIR" == "${SCRATCH_DISK}"* ]]; then
  ok "runner scratch on the SD card: $RUNNER_WORKDIR"
else
  warn "SD card not mounted — runner scratch falls back to $RUNNER_WORKDIR"
fi

# ---------------------------------------------------------------------------
# 3. Secrets + app.ini
# ---------------------------------------------------------------------------
log "writing configuration"
SECRET_KEY=$(random_hex 48)
INTERNAL_TOKEN=$(random_hex 48)

[[ -f /etc/forgejo/app.ini ]] && cp -a /etc/forgejo/app.ini /etc/forgejo/app.ini.bak.$(date +%s)

cat >/etc/forgejo/app.ini <<INI
APP_NAME = Forgejo
RUN_USER = forgejo
RUN_MODE = prod
WORK_PATH = ${BOOT_DATA}

[server]
PROTOCOL = http
DOMAIN = ${FORGEJO_DOMAIN}
ROOT_URL = http://${FORGEJO_DOMAIN}:3000/
HTTP_ADDR = 0.0.0.0
HTTP_PORT = 3000
DISABLE_SSH = false
SSH_PORT = 2222
SSH_LISTEN_PORT = 2222
SSH_DOMAIN = ${FORGEJO_DOMAIN}
START_SSH_SERVER = true
LFS_START_SERVER = true
OFFLINE_MODE = false
LANDING_PAGE = explore

[database]
DB_TYPE = sqlite3
PATH = ${BOOT_DATA}/data/forgejo.db
SQLITE_JOURNAL_MODE = WAL
SQLITE_TIMEOUT = 500

[repository]
ROOT = ${REPO_ROOT}
DEFAULT_BRANCH = main

[security]
INSTALL_LOCK = true
SECRET_KEY = ${SECRET_KEY}
INTERNAL_TOKEN = ${INTERNAL_TOKEN}
PASSWORD_COMPLEXITY = off
MIN_PASSWORD_LENGTH = 8

[service]
DISABLE_REGISTRATION = true
REQUIRE_SIGNIN_VIEW = true
ENABLE_NOTIFY_MAIL = false
DEFAULT_ALLOW_CREATE_ORGANIZATION = false
DEFAULT_ENABLE_TIMETRACKING = true

[mailer]
ENABLED = false

[log]
MODE = file
LEVEL = Info
ROOT_PATH = ${BOOT_DATA}/log

[actions]
ENABLED = true
DEFAULT_ACTIONS_URL = https://data.forgejo.org
LOG_RETENTION_DAYS = 30
ARTIFACT_RETENTION_DAYS = 14

[storage]
PATH = ${BOOT_DATA}/data

[storage.actions_log]
PATH = ${ACTIONS_LOG}

[storage.actions_artifacts]
PATH = ${ACTIONS_ARTIFACTS}

[mirror]
ENABLED = true

[cron.update_mirrors]
SCHEDULE = @every 10m
PULL_LIMIT = 50
PUSH_LIMIT = 50

[cache]
ADAPTER = memory
INTERVAL = 24h
INI
chown forgejo:forgejo /etc/forgejo/app.ini
chmod 0660 /etc/forgejo/app.ini
ok "/etc/forgejo/app.ini written (secrets generated fresh)"

# ---------------------------------------------------------------------------
# 4. systemd drop-in
# ---------------------------------------------------------------------------
# The USB disk is NOT a hard dependency any more: the database, the
# repositories and the Actions storage all live on the internal SSD, so an
# unplugged USB disk degrades the backups but never stops Forgejo.
#
# If the operator has explicitly chosen to put Actions storage on the USB
# disk (USB_HOLDS_ACTIONS=1), the disk becomes a hard dependency again —
# otherwise Forgejo would write into an unmounted path and lose the data.
mkdir -p /etc/systemd/system/forgejo.service.d
if [[ "${USB_HOLDS_ACTIONS}" == "1" ]]; then
  log "USB disk will hold Actions storage — adding the mount dependency"
  cat >/etc/systemd/system/forgejo.service.d/storage.conf <<UNIT
[Unit]
# Without this the service starts on an unmounted ${USB_DISK} and writes the
# artifacts into the root filesystem.
RequiresMountsFor=${USB_DISK}

[Service]
ReadWritePaths=${USB_DISK} ${ACTIONS_LOG} ${ACTIONS_ARTIFACTS}
UNIT
else
  log "Actions storage is on the internal SSD — no USB mount dependency"
  rm -f /etc/systemd/system/forgejo.service.d/storage.conf
fi
systemctl daemon-reload
ok "forgejo.service.d/storage.conf updated"

# ---------------------------------------------------------------------------
# 5. Start the server FIRST
# ---------------------------------------------------------------------------
# The CLI needs an initialised database. Letting the server create and migrate
# the database on its first boot is more reliable than having the CLI do it.
log "starting forgejo"
systemctl enable --now forgejo.service
sleep 3
if wait_http "http://127.0.0.1:3000/api/v1/version" 40; then
  ok "forgejo is up on http://127.0.0.1:3000"
  curl -fsS http://127.0.0.1:3000/api/v1/version | sed 's/^/  /' || true
else
  systemctl status forgejo.service --no-pager -l | tail -30
  die "forgejo did not come up — see the log above"
fi

# ---------------------------------------------------------------------------
# 6. Admin user + API token
# ---------------------------------------------------------------------------
if [[ -z "${FORGEJO_PASSWORD}" ]]; then
  FORGEJO_PASSWORD=$(random_hex 12)
  GENERATED_PW=1
fi

"${FORGEJO_BIN}" --config /etc/forgejo/app.ini admin user create \
  --username "${FORGEJO_USER}" \
  --password "${FORGEJO_PASSWORD}" \
  --email "ci-admin@$(hostname -f 2>/dev/null || hostname)" \
  --admin --must-change-password=false >/dev/null 2>&1 \
  || warn "admin user create reported an error (may already exist)"

# API token for the mirror scripts (read+write on repos and issues)
TOK_OUT=$(as_user forgejo "${FORGEJO_BIN}" --config /etc/forgejo/app.ini \
  admin user generate-access-token \
    --username "${FORGEJO_USER}" --token-name oma-stack \
    --scopes all 2>&1) || TOK_OUT=""

FORGEJO_TOKEN=$(printf '%s' "$TOK_OUT" | grep -oE '[0-9a-f]{40}' | head -1)
if [[ -z "$FORGEJO_TOKEN" ]]; then
  FORGEJO_TOKEN=$(random_hex 40)
  warn "could not generate an API token via the CLI; using a random placeholder."
  note "create a real token at ${FORGEJO_URL_FOR_DISPLAY}/user/settings/applications"
  note "and write it into ${FORGEJO_TOKEN_FILE}"
fi
printf '%s' "$FORGEJO_TOKEN" >"${FORGEJO_TOKEN_FILE}"
chmod 0600 "${FORGEJO_TOKEN_FILE}"
ok "API token written to ${FORGEJO_TOKEN_FILE}"

cat <<EOF

  Admin user : ${FORGEJO_USER}
  Password   : ${FORGEJO_PASSWORD}$( [[ "${GENERATED_PW:-0}" == "1" ]] && echo "  <- save this now, it is not stored anywhere" )
  API token  : ${FORGEJO_TOKEN_FILE}

  Write that password somewhere safe. The install scripts cannot recover it.
EOF
