#!/usr/bin/env bash
# verify/healthcheck.sh — is the whole oma-stack healthy?
#
# Runs the Forgejo layer's own healthcheck, then adds the checks for the
# parts that layer knows nothing about: OpenBot and the agent bridge.
#
# Three states:
#   PASS  everything is fine
#   WARN  degraded but not fatal (e.g. the optional USB backup disk is absent)
#   FAIL  something that breaks CI, the agent surface, or data safety
#
# Exits non-zero only on FAIL.  Run by systemd every ${HEALTHCHECK_INTERVAL_MIN}
# minutes and by hand whenever something looks wrong.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
source "${ROOT}/stack/install/_lib.sh"
source "${HOST_ENV}"

STATUS_FILE="/var/log/oma-stack-health.log"
RESULTS=()
PROBLEMS=0
WARNINGS=0

check() {
  local name="$1" state="$2" detail="$3"
  case "$state" in
    yes) RESULTS+=("PASS  ${name}: ${detail}") ;;
    warn) RESULTS+=("WARN  ${name}: ${detail}"); WARNINGS=$((WARNINGS+1)) ;;
    *)   RESULTS+=("FAIL  ${name}: ${detail}"); PROBLEMS=$((PROBLEMS+1)) ;;
  esac
}

# ---------------------------------------------------------------------------
# 1. The Forgejo + CI layer
# ---------------------------------------------------------------------------
STACK_OUT=""
if [[ -x "${ROOT}/stack/verify/healthcheck.sh" ]]; then
  # The stack's own healthcheck exits non-zero when it finds a problem, and
  # those problems are this report's problems.  Do not stop on it.
  STACK_OUT="$(bash "${ROOT}/stack/verify/healthcheck.sh" 2>&1)" || true
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    case "$line" in
      "PASS  "*) RESULTS+=("$line") ;;
      "WARN  "*) RESULTS+=("$line"); WARNINGS=$((WARNINGS+1)) ;;
      "FAIL  "*) RESULTS+=("$line"); PROBLEMS=$((PROBLEMS+1)) ;;
    esac
  done <<<"$STACK_OUT"
else
  check "stack.healthcheck" no "not found at ${ROOT}/stack/verify/healthcheck.sh"
fi

# ---------------------------------------------------------------------------
# 2. OpenBot
# ---------------------------------------------------------------------------
if [[ "${ENABLE_OPENBOT:-1}" == "1" ]]; then
  if systemctl is-active --quiet oma-openbot.service 2>/dev/null; then
    check "openbot.service" yes "active"
  else
    check "openbot.service" no "not active"
  fi

  if have docker; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "oma-openbot"; then
      check "openbot.container" yes "running"
    else
      check "openbot.container" no "the oma-openbot container is not running"
    fi
  fi

  if curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:${OPENBOT_PORT:-3001}/health"; then
    check "openbot.http" yes "answering on ${OPENBOT_PORT}"
  else
    check "openbot.http" no "no answer on http://127.0.0.1:${OPENBOT_PORT:-3001}/health"
  fi

  # The two values OpenBot refuses to start without.  Missing keys are a
  # warning, not a failure: the server may already be running with them.
  if [[ -f "${CRED_DIR}/openbot.env" ]]; then
    grep -qE '^CPK_INTELLIGENCE_API_KEY=.+' "${CRED_DIR}/openbot.env" \
      || check "openbot.intelligence" warn "CPK_INTELLIGENCE_API_KEY is not set"
    grep -qE '^(OPENAI_API_KEY|ANTHROPIC_API_KEY|GOOGLE_API_KEY)=.+' "${CRED_DIR}/openbot.env" \
      || check "openbot.model" warn "no model key is set"
  else
    check "openbot.env" no "${CRED_DIR}/openbot.env does not exist"
  fi
fi

# ---------------------------------------------------------------------------
# 3. The agent bridge
# ---------------------------------------------------------------------------
if [[ "${ENABLE_AGENT_BRIDGE:-1}" == "1" ]]; then
  if systemctl is-active --quiet oma-agent-bridge.service 2>/dev/null; then
    check "agent-bridge.service" yes "active"
  else
    check "agent-bridge.service" no "not active"
  fi

  BRIDGE="http://127.0.0.1:${AGENT_BRIDGE_PORT:-8765}"
  if HEALTH="$(curl -fsS --max-time 5 "${BRIDGE}/health" 2>/dev/null)"; then
    NAMES="$(printf '%s' "$HEALTH" | grep -oE '"agents": \[[^]]*\]' | tr -d '[]"' | sed 's/agents: //' || true)"
    check "agent-bridge.http" yes "answering on ${AGENT_BRIDGE_PORT}"
    if [[ -n "${NAMES}" ]]; then
      check "agent-bridge.agents" yes "${NAMES}"
    else
      check "agent-bridge.agents" warn "no agents registered"
    fi
  else
    check "agent-bridge.http" no "no answer on ${BRIDGE}/health"
  fi

  if [[ -d "${HANDOFF_WATCH_DIR:-/var/lib/oma-stack/handoff/inbox}" ]]; then
    check "handoff.inbox" yes "${HANDOFF_WATCH_DIR}"
  else
    check "handoff.inbox" no "${HANDOFF_WATCH_DIR} does not exist"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Report
# ---------------------------------------------------------------------------
STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
  echo "[${STAMP}] $(printf '%s\n' "${RESULTS[@]}" | grep -c '^PASS') pass, ${WARNINGS} warn, ${PROBLEMS} fail"
  printf '%s\n' "${RESULTS[@]}"
  echo
} >>"$STATUS_FILE" 2>/dev/null || true

printf '%s\n' "${RESULTS[@]}"
if (( PROBLEMS > 0 )); then
  echo
  warn "${PROBLEMS} problem(s) found — see ${STATUS_FILE}"
  exit 1
fi
if (( WARNINGS > 0 )); then
  echo
  warn "${WARNINGS} warning(s) — see ${STATUS_FILE}"
fi
ok "all checks passed"
