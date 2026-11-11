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
cred_dir_ensure

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

# The default agent must be one that can actually run, and the chain is the
# order the agents take over in.  An agent whose program is not on the PATH
# is disabled, so the bridge never offers an endpoint that cannot answer.
python3 - "${AGENT_BRIDGE_REGISTRY}" "${AGENT_DEFAULT:-auto}" <<'PY'
import json, os, shutil, sys

path, preferred = sys.argv[1], sys.argv[2]
raw = json.load(open(path))
chain = list(raw.get("chain") or [])
agents = raw.get("agents", [])
by_name = {a.get("name"): a for a in agents}

disabled = []
for agent in agents:
    command = agent.get("command") or []
    if not command:
        continue
    binary = command[0]
    if shutil.which(binary) is None:
        agent["command"] = []
        agent["disabled_reason"] = f"'{binary}' is not on the PATH"
        disabled.append(agent.get("name", "?"))

def runnable(name):
    agent = by_name.get(name)
    return bool(agent and agent.get("command"))

# The default is the first runnable agent in the chain — unless the config
# names one explicitly and that one can run.
order = chain or [a.get("name") for a in agents]
chosen = None
if preferred and preferred != "auto" and runnable(preferred):
    chosen = preferred
else:
    chosen = next((n for n in order if runnable(n)), None)
if not chosen:
    chosen = next((a.get("name") for a in agents if a.get("command")), None)

if chosen:
    raw["default"] = chosen

json.dump(raw, open(path, "w"), indent=2)
print("DEFAULT=" + str(raw.get("default")))
print("DISABLED=" + ",".join(disabled))
PY

DEFAULT="$(python3 -c "
import json,sys
print(json.load(open('${AGENT_BRIDGE_REGISTRY}')).get('default',''))
")"
ok "default agent: ${DEFAULT:-none}"

DISABLED="$(python3 -c "
import json,sys
raw=json.load(open('${AGENT_BRIDGE_REGISTRY}'))
print(', '.join(a['name'] for a in raw.get('agents',[]) if a.get('disabled_reason')))
")"
[[ -z "${DISABLED}" ]] || warn "not runnable on this box: ${DISABLED}"

# The bridge reads the registry AS THE OPERATOR, so the operator must own it.
# The file lives in a root-owned 0711 directory: the operator can read and
# edit the file, but cannot add or delete files in the directory.
chown "${OPERATOR}" "${AGENT_BRIDGE_REGISTRY}" 2>/dev/null || \
  warn "could not chown ${AGENT_BRIDGE_REGISTRY} to ${OPERATOR}"
chmod 0600 "${AGENT_BRIDGE_REGISTRY}"
ok "registry owned by ${OPERATOR}"

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
Environment=AGENT_BRIDGE_HEARTBEAT_SECONDS=${AGENT_BRIDGE_HEARTBEAT_SECONDS:-15}
ExecStart=${ROOT}/components/agents/bridge.py \\
  --registry ${AGENT_BRIDGE_REGISTRY} \\
  --bind ${AGENT_BRIDGE_BIND} \\
  --port ${AGENT_BRIDGE_PORT} \\
  --allow-ips ${AGENT_BRIDGE_ALLOWED_IPS} \\
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
