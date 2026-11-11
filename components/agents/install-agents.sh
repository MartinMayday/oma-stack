#!/usr/bin/env bash
# install-agents.sh — run the agent bridge.
#
# The bridge is what makes OpenBot and the local agents one system:
#
#   OpenBot  --AG-UI-->  bridge  --stdin-->  qoder / glm / minimax
#
# It also works the handoff queue: a case file with an assignee is run, and
# its answer is written to the outbox for a human to approve.  The bridge
# never merges, deploys, or touches a credential.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
source "${ROOT}/stack/install/_lib.sh"
source "${HOST_ENV}"

need_root "$@"

# ---------------------------------------------------------------------------
# 1. Who runs it
# ---------------------------------------------------------------------------
# The agents live in the operator's home (their sessions, their credentials),
# so the bridge runs as the operator, not as a stripped system account.
OPERATOR="${AGENT_BRIDGE_USER:-${SUDO_USER:-}}"
if [[ -z "${OPERATOR}" ]]; then
  OPERATOR="$(id -un)"
fi
if ! id -u "${OPERATOR}" >/dev/null 2>&1; then
  OPERATOR="oma-bridge"
  id -u "${OPERATOR}" >/dev/null 2>&1 || \
    useradd --system --home-dir /var/lib/oma-stack --shell /bin/bash "${OPERATOR}"
  ok "created the system account ${OPERATOR}"
fi
ok "bridge runs as ${OPERATOR}"
OPERATOR_HOME="$(getent passwd "${OPERATOR}" | cut -d: -f6)"

# ---------------------------------------------------------------------------
# 2. Python
# ---------------------------------------------------------------------------
log "checking python"
if ! have python3; then
  log "installing python"
  pkg_install python
fi
ok "python $(python3 --version | cut -d' ' -f2)"

# ---------------------------------------------------------------------------
# 3. The registry
# ---------------------------------------------------------------------------
log "writing the agent registry"
install -d -m 0700 "${CRED_DIR}"

AGENTLIB="${AGENTLIB_PATH:-${OPERATOR_HOME}/agent-library}"
[[ -d "${AGENTLIB}" ]] || AGENTLIB="${OPERATOR_HOME}"

if [[ ! -f "${AGENT_BRIDGE_REGISTRY}" ]]; then
  sed -e "s|@AGENTLIB@|${AGENTLIB}|g" "${HERE}/agents.json" >"${AGENT_BRIDGE_REGISTRY}"
  chmod 0600 "${AGENT_BRIDGE_REGISTRY}"
  ok "registry written to ${AGENT_BRIDGE_REGISTRY}"
  NEW_REGISTRY=1
else
  ok "registry already exists — kept (${AGENT_BRIDGE_REGISTRY})"
  NEW_REGISTRY=0
fi

# The default agent must be one that can actually run.
DEFAULT="${AGENT_DEFAULT}"
if python3 - "${AGENT_BRIDGE_REGISTRY}" "${DEFAULT}" <<'PY'
import json, sys
path, want = sys.argv[1], sys.argv[2]
raw = json.load(open(path))
agents = {a.get("name"): a for a in raw.get("agents", [])}
spec = agents.get(want)
sys.exit(0 if spec and spec.get("command") else 1)
PY
then
  ok "default agent '${DEFAULT}' is configured"
else
  FIRST="$(python3 - "${AGENT_BRIDGE_REGISTRY}" <<'PY'
import json, sys
raw = json.load(open(sys.argv[1]))
for a in raw.get("agents", []):
    if a.get("command"):
        print(a.get("name", ""))
        break
PY
)"
  if [[ -n "${FIRST}" ]]; then
    python3 - "${AGENT_BRIDGE_REGISTRY}" "${FIRST}" <<'PY'
import json, sys
path, first = sys.argv[1], sys.argv[2]
raw = json.load(open(path))
raw["default"] = first
json.dump(raw, open(path, "w"), indent=2)
PY
    warn "default agent '${DEFAULT}' has no command — defaulting to '${FIRST}'"
    note "fill the command in:  sudo nano ${AGENT_BRIDGE_REGISTRY}"
  else
    warn "no agent in the registry has a command yet"
    note "fill one in:  sudo nano ${AGENT_BRIDGE_REGISTRY}"
  fi
fi

# ---------------------------------------------------------------------------
# 4. The handoff queue
# ---------------------------------------------------------------------------
log "preparing the handoff queue"
install -d -m 0755 "${HANDOFF_ROOT}"
install -d -m 0755 "${HANDOFF_WATCH_DIR}"
install -d -m 0755 "${HANDOFF_ROOT}/outbox"
install -d -m 0755 "${HANDOFF_ROOT}/done"
install -d -m 0755 "${HANDOFF_ROOT}/failed"
touch "${HANDOFF_ROOT}/audit.log"
chown -R "${OPERATOR}" "${HANDOFF_ROOT}" 2>/dev/null || true
ok "inbox ${HANDOFF_WATCH_DIR}"

# ---------------------------------------------------------------------------
# 5. systemd unit
# ---------------------------------------------------------------------------
log "installing the systemd unit"
cat >/etc/systemd/system/oma-agent-bridge.service <<UNIT
[Unit]
Description=oma-stack agent bridge — local agents over AG-UI, plus the handoff queue
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${OPERATOR}
Group=${OPERATOR}
WorkingDirectory=${ROOT}
Environment=PYTHONUNBUFFERED=1
ExecStart=${ROOT}/components/agents/bridge.py \\
  --registry ${AGENT_BRIDGE_REGISTRY} \\
  --bind ${AGENT_BRIDGE_BIND} \\
  --port ${AGENT_BRIDGE_PORT} \\
  --handoff-root ${HANDOFF_ROOT} \\
  --inbox ${HANDOFF_WATCH_DIR}
Restart=on-failure
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT
chmod 0755 "${ROOT}/components/agents/bridge.py"
systemctl daemon-reload
systemctl enable --now oma-agent-bridge.service
sleep 2

if systemctl is-active --quiet oma-agent-bridge.service; then
  ok "oma-agent-bridge.service is active"
else
  journalctl -u oma-agent-bridge.service -n 30 --no-pager | tail -20
  warn "the bridge is not running — check the log above"
fi

# ---------------------------------------------------------------------------
# 6. Prove it
# ---------------------------------------------------------------------------
BRIDGE_URL="http://127.0.0.1:${AGENT_BRIDGE_PORT}"
if curl -fsS --max-time 5 "${BRIDGE_URL}/health" >/dev/null 2>&1; then
  ok "bridge answers on ${BRIDGE_URL}"
else
  warn "no answer on ${BRIDGE_URL}/health"
fi

AGENTS="$(curl -fsS --max-time 5 "${BRIDGE_URL}/agents" 2>/dev/null \
  | grep -oE '"name": "[^"]+"' | sed 's/"name": //; s/"//g' | tr '\n' ' ' || true)"
ok "agents: ${AGENTS:-none}"

cat <<EOF

  AG-UI endpoints (register these in OpenBot):
    http://host.docker.internal:${AGENT_BRIDGE_PORT}/ag-ui/<agent>

  From this machine:
    http://127.0.0.1:${AGENT_BRIDGE_PORT}/ag-ui/<agent>

  Handoff inbox : ${HANDOFF_WATCH_DIR}
  Outbox        : ${HANDOFF_ROOT}/outbox
  Audit log     : ${HANDOFF_ROOT}/audit.log
EOF
