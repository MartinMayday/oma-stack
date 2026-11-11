#!/usr/bin/env bash
# 20-forgejo-runner.sh — install the Forgejo Actions runner (CI executor).
#
# The runner binary comes from code.forgejo.org (NOT codeberg). There is no
# default config path: -c is mandatory.
#
# On this box we use a HOST label ("self-hosted:host"), meaning jobs run
# directly on the MacBook with no container. That is the right choice for
# 2 cores / 8 GB: a docker label would add ~2 GB RAM and a ~1 GB image pull
# for no benefit at this scale.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/_lib.sh"
source "${HOST_ENV}"

need_root "$@"

RUNNER_VERSION="${RUNNER_VERSION:-13.2.1}"
RUNNER_URL="https://code.forgejo.org/forgejo/runner/releases/download/v${RUNNER_VERSION}/forgejo-runner-${RUNNER_VERSION}-linux-amd64"

# ---------------------------------------------------------------------------
# 1. Binary
# ---------------------------------------------------------------------------
log "installing forgejo-runner ${RUNNER_VERSION}"
if [[ -x /usr/local/bin/forgejo-runner ]]; then
  ok "already installed"
else
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/runner" "$RUNNER_URL" \
    || die "download failed: $RUNNER_URL"
  # verify the checksum the release publishes alongside the asset
  if curl -fsSL -o "$tmp/runner.sha256" \
      "https://code.forgejo.org/forgejo/runner/releases/download/v${RUNNER_VERSION}/forgejo-runner-${RUNNER_VERSION}-linux-amd64.sha256" 2>/dev/null; then
    expected=$(tr -d '[:space:]' <"$tmp/runner.sha256")
    actual=$(sha256sum "$tmp/runner" | cut -d' ' -f1)
    if [[ "$expected" == *"$actual"* || "$actual" == "$expected" ]]; then
      ok "sha256 verified"
    else
      rm -rf "$tmp"; die "sha256 mismatch — refusing to install"
    fi
  else
    warn "no .sha256 published for this release; installing unverified"
  fi
  install -m 0755 "$tmp/runner" /usr/local/bin/forgejo-runner
  rm -rf "$tmp"
  ok "/usr/local/bin/forgejo-runner installed"
fi

# ---------------------------------------------------------------------------
# 2. Runner user + work dir
# ---------------------------------------------------------------------------
log "preparing the runner account"
id -u "$RUNNER_USER" >/dev/null 2>&1 || \
  useradd --create-home --shell /bin/bash "$RUNNER_USER"

# Scratch: the SD card when it is inserted, the internal SSD otherwise.
RUNNER_WORKDIR="$(runner_workdir)"
install -d -o "$RUNNER_USER" -g "$RUNNER_USER" "$RUNNER_WORKDIR"
install -d -o "$RUNNER_USER" -g "$RUNNER_USER" /var/cache/forgejo-runner
if [[ "$RUNNER_WORKDIR" == "${SCRATCH_DISK}"* ]]; then
  ok "work dir $RUNNER_WORKDIR (SD card scratch)"
else
  warn "SD card not mounted — work dir $RUNNER_WORKDIR (internal SSD)"
fi

# ---------------------------------------------------------------------------
# 3. Register with the Forgejo instance
# ---------------------------------------------------------------------------
FORGEJO_URL="http://127.0.0.1:3000"
RUNNER_CFG="/home/${RUNNER_USER}/runner-config.yml"

if [[ -f "$RUNNER_CFG" ]] && grep -q "token:" "$RUNNER_CFG" 2>/dev/null; then
  ok "runner already registered ($RUNNER_CFG)"
else
  log "registering the runner with Forgejo"

  # The CLI path: forgejo-cli actions register prints the UUID and the
  # 40-hex secret that becomes the runner token.
  REG_OUT=$(as_user forgejo "${FORGEJO_BIN}" --config /etc/forgejo/app.ini \
    forgejo-cli actions register \
      --name "${RUNNER_NAME:-macbook-forge}" \
      --scope "${FORGEJO_USER}" \
      --secret "$(random_hex 40)" 2>&1) || REG_OUT=""

  RUNNER_UUID=$(printf '%s' "$REG_OUT" | grep -oE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' | head -1)
  RUNNER_TOKEN=$(printf '%s' "$REG_OUT" | grep -oE '[0-9a-f]{40}' | head -1)

  if [[ -z "$RUNNER_UUID" ]]; then
    note "automatic registration failed; register by hand and re-run:"
    note "  1. open http://127.0.0.1:3000/user/settings/actions/runners"
    note "  2. create a runner, note the UUID and the 40-character token"
    note "  3. put them into ${RUNNER_CFG} and run: systemctl start forgejo-runner"
    printf '%s' "$REG_OUT" | tail -5 | sed 's/^/       /'
  else
    LABELS_BLOCK=""
    for l in $RUNNER_LABELS; do LABELS_BLOCK+="    - \"${l}\"\n"; done
    if [[ "${ENABLE_DOCKER_LABEL}" == "1" ]]; then
      LABELS_BLOCK+="    - \"${DOCKER_LABEL}\"\n"
    fi

    cat >"$RUNNER_CFG" <<CFG
server:
  connections:
    forgejo:
      url: ${FORGEJO_URL}/
      uuid: ${RUNNER_UUID}
      token: ${RUNNER_TOKEN}
runner:
  file: .runner
  capacity: ${RUNNER_CAPACITY}
  timeout: 3h
  labels:
$(printf '%b' "$LABELS_BLOCK")
host:
  workdir_parent: ${RUNNER_WORKDIR}
cache:
  enabled: true
  port: 0
  dir: /var/cache/forgejo-runner
CFG
    chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_CFG"
    chmod 0600 "$RUNNER_CFG"
    ok "runner registered (uuid ${RUNNER_UUID})"
  fi
fi

# ---------------------------------------------------------------------------
# 4. systemd unit
# ---------------------------------------------------------------------------
log "installing the systemd unit"
cat >/etc/systemd/system/forgejo-runner.service <<UNIT
[Unit]
Description=Forgejo Actions runner
After=network.target forgejo.service
Requires=forgejo.service

[Service]
Type=simple
User=${RUNNER_USER}
Group=${RUNNER_USER}
WorkingDirectory=/home/${RUNNER_USER}
Environment=ACTIONS_RUNNER_HOOK_JOB_COMPLETED_ENVIRONMENT=/var/log/forgejo-runner
ExecStart=/usr/local/bin/forgejo-runner daemon -c ${RUNNER_CFG}
ExecReload=/bin/kill -s HUP \$MAINPID
Restart=on-failure
RestartSec=10
TimeoutStopSec=infinity
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload

if [[ -f "$RUNNER_CFG" ]]; then
  systemctl enable --now forgejo-runner.service
  sleep 4
  if systemctl is-active --quiet forgejo-runner.service; then
    ok "forgejo-runner.service is active"
  else
    journalctl -u forgejo-runner.service -n 30 --no-pager | tail -20
    warn "runner service is not active — check the log above"
  fi
else
  warn "runner not registered yet; service installed but not started"
fi
