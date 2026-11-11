#!/usr/bin/env bash
# install-openbot.sh — install and run OpenBot (CopilotKit/OpenBot).
#
# One container carries the app, the API, the browser the Bots drive and the
# database.  On an 8 GB laptop that matters: the full source deployment wants
# Bun, a PostgreSQL of its own and two more services.
#
# What OpenBot refuses to start without is exactly this: a key encryption
# key, the Intelligence coordinates (API URL, gateway WS URL, API key) and an
# identity — which OPENBOT_SINGLE_USER=true supplies.  A *model* key is only
# needed by OpenBot's own Bots, and the all-in-one image ships none.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
source "${ROOT}/stack/install/_lib.sh"
source "${HOST_ENV}"

need_root "$@"

ENV_FILE="${CRED_DIR}/openbot.env"
PROJECT_DIR="${ROOT}/components/openbot"

# ---------------------------------------------------------------------------
# 1. Docker
# ---------------------------------------------------------------------------
log "checking docker"
if ! have docker; then
  log "installing docker"
  pkg_install docker docker-compose
fi
ok "docker $(docker --version | head -1)"

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif have docker-compose; then
  COMPOSE=(docker-compose)
else
  pkg_install docker-compose
  if have docker-compose; then
    COMPOSE=(docker-compose)
  else
    die "docker compose is not available — install the docker-compose package"
  fi
fi
ok "compose: ${COMPOSE[*]}"

systemctl enable --now docker.service >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 2. Secrets and configuration
# ---------------------------------------------------------------------------
log "writing the OpenBot configuration"
cred_dir_ensure
install -d -m 0755 "${OPENBOT_DATA_DIR}"

DESIRED="$(mktemp)"
SECRETS="$(mktemp)"
trap 'rm -f "${DESIRED}" "${SECRETS}"' EXIT

# A secret already in the env file is kept: rotating it would invalidate
# every credential OpenBot has encrypted with it.
ensure_secret() {
  local key="$1" generator="$2" current=""
  if [[ -f "${ENV_FILE}" ]]; then
    current="$(grep -m1 "^${key}=" "${ENV_FILE}" 2>/dev/null | cut -d= -f2- || true)"
  fi
  if [[ -z "${current}" ]]; then
    printf '%s=%s\n' "${key}" "$("$generator")" >>"${SECRETS}"
    ok "generated ${key}"
  else
    ok "${key} already set — kept"
  fi
}

ensure_secret KEY_ENCRYPTION_KEY    "openssl rand -base64 32"
ensure_secret BETTER_AUTH_SECRET   "openssl rand -base64 32"
ensure_secret COMPUTER_TOKEN        "openssl rand -hex 32"
ensure_secret SUPERVISOR_TOKEN      "openssl rand -hex 32"
ensure_secret AGENT_TOOL_TOKEN      "openssl rand -hex 32"
ensure_secret WORKER_SHARED_SECRET  "openssl rand -hex 32"
ensure_secret MANAGED_AGENT_TOKEN   "openssl rand -hex 32"

# --- the agent endpoint allowlist -----------------------------------------
# Private addresses an agent may be registered at.  The format is host or
# host:port, comma separated, with no scheme, no path and no wildcards: a URL
# or a "*" here stops OpenBot from starting, naming the offending entry.
#
# The list permits private addresses; it does not restrict which agents may be
# registered at a public address.  The match is exact against the hostname of
# the registered URL, so the URL you register must use one of these names.
#
# The registered agent URL therefore has to be:
#     http://host.docker.internal:8765/ag-ui/<name>
# Inside the container 127.0.0.1 is the container, not this machine, so a
# loopback URL can never reach the bridge.
ALLOWED="${OPENBOT_AGENT_ENDPOINT_ALLOWED_HOSTS:-}"
if [[ "${ENABLE_AGENT_BRIDGE}" == "1" ]]; then
  BRIDGE_HOST="host.docker.internal:${AGENT_BRIDGE_PORT}"
  ALLOWED="${ALLOWED:+${ALLOWED},}${BRIDGE_HOST}"
  GATEWAY="$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)"
  if [[ -n "${GATEWAY}" ]]; then
    ALLOWED="${ALLOWED},${GATEWAY}:${AGENT_BRIDGE_PORT}"
  fi
fi
ALLOWED="${ALLOWED%,}"

cat >"${DESIRED}" <<EOF
# Written by oma-stack. Edits here are overwritten on the next install;
# edit ${CRED_DIR}/openbot.env instead — values already in that file win.
KEY_ENCRYPTION_KEY=
BETTER_AUTH_SECRET=
COMPUTER_TOKEN=
SUPERVISOR_TOKEN=
AGENT_TOOL_TOKEN=
WORKER_SHARED_SECRET=
# MANAGED_AGENT_TOKEN is inert without MANAGED_AGENT_AG_UI_URL: upstream
# ignores a leftover token when no URL is set, and the one-image deployment
# carries no managed Bot.  It is kept so a managed Bot can be switched on
# later without regenerating anything.
MANAGED_AGENT_TOKEN=
OPENBOT_SINGLE_USER=${OPENBOT_SINGLE_USER}
TRUSTED_ORIGINS=http://localhost:${OPENBOT_PORT},http://127.0.0.1:${OPENBOT_PORT}
INTELLIGENCE_API_URL=${OPENBOT_INTELLIGENCE_API_URL}
INTELLIGENCE_GATEWAY_WS_URL=${OPENBOT_INTELLIGENCE_GATEWAY_WS_URL}
CPK_INTELLIGENCE_API_KEY=${OPENBOT_INTELLIGENCE_API_KEY}
AGENT_ENDPOINT_ALLOWED_HOSTS=${ALLOWED}
# How long a Bot's stream may stay silent before OpenBot gives up on the
# turn.  The default is 60 s, which is shorter than the latency of a real
# agent behind the bridge; the bridge also sends a heartbeat, so this is the
# backstop, not the normal path.
AGENT_STALL_TIMEOUT_MS=${OPENBOT_STALL_TIMEOUT_MS:-300000}
EOF

# BOT_PROVIDER and BOT_MODEL belong to OpenBot's own framework Bots.  The
# all-in-one image ships none of them, so these two are inert here: the
# model that answers is the one behind the agent you registered.  They are
# written so the file is complete for anyone who later deploys a harness
# Bot in the same image.
case "${OPENBOT_MODEL_PROVIDER}" in
  anthropic) printf 'BOT_PROVIDER=anthropic\n' >>"${DESIRED}" ;;
  google)    printf 'BOT_PROVIDER=google\n'    >>"${DESIRED}" ;;
  *)         printf 'BOT_PROVIDER=openai\n'    >>"${DESIRED}" ;;
esac
[[ -n "${OPENBOT_MODEL}" ]] && printf 'BOT_MODEL=%s\n' "${OPENBOT_MODEL}" >>"${DESIRED}"

# A computer policy that refuses the three commands nobody wants a Bot to
# run, and allows everything else.  `deny` is evaluated first and beats
# `allow`; a malformed policy stops the server rather than opening it up.
#
# The upstream shell tool is `computer_run_command`, but upstream's own
# idiom for "a shell command is running" is the `intent` attribute, so the
# deny rule keys off `intent == "run_command"`.  Denying a tool name that
# does not exist is a rule that never fires, which is worse than no rule.
cat >>"${DESIRED}" <<'EOF'
AGENT_COMPUTER_POLICY={"mode":"enforce","deny":["intent == \"run_command\" && (contains(command, \"rm -rf /\") || contains(command, \"rm -fr /\") || contains(command, \"mkfs\") || contains(command, \"dd if=\") || contains(command, \":(){ :|:&};:\"))"],"allow":["true"]}
EOF

# The model key is not in host.env.  It comes from the operator, either in
# the env file already or typed in later.
for key in OPENAI_API_KEY ANTHROPIC_API_KEY GOOGLE_API_KEY COPILOTKIT_LICENSE_TOKEN; do
  grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null || printf '%s=\n' "${key}" >>"${DESIRED}"
done

# Merge: what is already in the env file wins, the desired file fills gaps.
MERGED="$(mktemp)"
if [[ -f "${ENV_FILE}" ]]; then
  grep -vE '^[[:space:]]*(#|$)' "${ENV_FILE}" >"${MERGED}" || true
fi
while IFS= read -r line; do
  [[ -z "${line}" || "${line}" == \#* ]] && continue
  key="${line%%=*}"
  grep -q "^${key}=" "${MERGED}" || printf '%s\n' "${line}" >>"${MERGED}"
done <"${DESIRED}"
while IFS= read -r line; do
  [[ -z "${line}" || "${line}" == \#* ]] && continue
  key="${line%%=*}"
  grep -q "^${key}=" "${MERGED}" || printf '%s\n' "${line}" >>"${MERGED}"
done <"${SECRETS}"

install -m 0600 "${MERGED}" "${ENV_FILE}"
rm -f "${MERGED}"
ok "environment written to ${ENV_FILE} (mode 0600)"

# ---------------------------------------------------------------------------
# 3. Compose project settings
# ---------------------------------------------------------------------------
cat >"${PROJECT_DIR}/.env" <<EOF
OPENBOT_IMAGE=${OPENBOT_IMAGE}
OPENBOT_PORT=${OPENBOT_PORT}
OPENBOT_BIND=${OPENBOT_BIND:-127.0.0.1}
OPENBOT_VOLUME=${OPENBOT_VOLUME}
OPENBOT_DATA_DIR=${OPENBOT_DATA_DIR}
EOF
ok "compose settings written to ${PROJECT_DIR}/.env"

# ---------------------------------------------------------------------------
# 4. systemd unit
# ---------------------------------------------------------------------------
log "installing the systemd unit"
cat >/etc/systemd/system/oma-openbot.service <<UNIT
[Unit]
Description=OpenBot (CopilotKit) — the agent surface
After=network-online.target docker.service
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${PROJECT_DIR}
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
ok "oma-openbot.service installed"

# ---------------------------------------------------------------------------
# 4b. The scheduled worker
# ---------------------------------------------------------------------------
# The image ships no scheduler, so the routines sweep and the staged
# attachment sweep would never run.  The wrapper runs both inside the
# running container, where the server's own environment applies.
log "installing the scheduled worker"
install -m 0755 "${PROJECT_DIR}/openbot-worker.sh" /usr/local/bin/oma-openbot-worker

cat >/etc/systemd/system/oma-openbot-worker.service <<UNIT
[Unit]
Description=OpenBot scheduled worker — routines and staged-attachment sweep
After=docker.service oma-openbot.service
Requires=docker.service
Wants=oma-openbot.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/oma-openbot-worker
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
UNIT

cat >/etc/systemd/system/oma-openbot-worker.timer <<UNIT
[Unit]
Description=Run the OpenBot scheduled worker every hour

[Timer]
OnCalendar=*-*-* *:05:00
Persistent=true
RandomizedDelaySec=120
Unit=oma-openbot-worker.service

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
if [[ "${OPENBOT_WORKER_TIMER:-1}" == "1" ]]; then
  systemctl enable --now oma-openbot-worker.timer >/dev/null 2>&1 || \
    warn "could not enable oma-openbot-worker.timer"
  ok "oma-openbot-worker.timer installed (hourly)"
else
  ok "oma-openbot-worker.timer installed but not enabled"
fi

# ---------------------------------------------------------------------------
# 5. Start it
# ---------------------------------------------------------------------------
log "pulling the image"
( cd "${PROJECT_DIR}" && "${COMPOSE[@]}" pull ) || warn "image pull failed — retrying at start"

log "starting OpenBot"
systemctl enable --now oma-openbot.service || {
  ( cd "${PROJECT_DIR}" && "${COMPOSE[@]}" up -d --remove-orphans )
}

log "waiting for the API to answer"
READY=0
for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${OPENBOT_PORT}/health"; then
    READY=1; break
  fi
  sleep 2
done

if (( READY )); then
  ok "OpenBot is up on http://127.0.0.1:${OPENBOT_PORT}"
else
  warn "OpenBot did not answer on /health within two minutes."
  note "check:  docker logs oma-openbot --tail 60"
  note "the usual cause is a missing Intelligence key — see below."
fi

# ---------------------------------------------------------------------------
# 6. What is still missing
# ---------------------------------------------------------------------------
# The hard blockers are the Intelligence coordinates and the key encryption
# key.  A model key is only needed by OpenBot's own Bots, and the all-in-one
# image ships none — the agents that answer are the ones you registered.
MISSING=""
grep -qE '^CPK_INTELLIGENCE_API_KEY=.+' "${ENV_FILE}" || MISSING="${MISSING} CPK_INTELLIGENCE_API_KEY"
grep -qE '^KEY_ENCRYPTION_KEY=.+' "${ENV_FILE}" || MISSING="${MISSING} KEY_ENCRYPTION_KEY"

# A model key is a note, not a blocker.
MODEL_KEY=0
grep -qE '^(OPENAI_API_KEY|ANTHROPIC_API_KEY|GOOGLE_API_KEY)=.+' "${ENV_FILE}" || MODEL_KEY=1

cat <<EOF

  OpenBot      : http://127.0.0.1:${OPENBOT_PORT}
  environment  : ${ENV_FILE}
  project dir  : ${PROJECT_DIR}

EOF
if [[ -n "${MISSING}" ]]; then
  warn "still needed:${MISSING}"
  note "add them with:  sudo nano ${ENV_FILE}"
  note "then:           sudo systemctl restart oma-openbot.service"
  note ""
  note "for the Intelligence key:"
  note "  npx --yes copilotkit@latest login"
  note "  npx --yes copilotkit@latest project select"
  note "  (or, for local Intelligence: npx --yes copilotkit@latest local connect)"
else
  ok "every required value is set"
fi

if (( MODEL_KEY )); then
  note ""
  note "no model key — fine.  A model key is only needed by OpenBot's own"
  note "Bots, and the one-image deployment ships none.  The model that"
  note "answers you is the one behind the agent you registered."
fi

if [[ "${ENABLE_AGENT_BRIDGE}" == "1" ]]; then
  note ""
  note "register the agent in OpenBot with this URL:"
  note "  http://host.docker.internal:${AGENT_BRIDGE_PORT}/ag-ui/qoder"
  note "and add the agent names you want (qoder, glm, minimax) to"
  note "  ${CRED_DIR}/openbot.env"
  note "as AGENT_ENDPOINT_ALLOWED_HOSTS entries — host or host:port, no scheme."
fi
