#!/usr/bin/env bash
# install.sh — install the whole oma-stack on this machine.
#
#   sudo ./install.sh                    everything
#   sudo ./install.sh --no-openbot       skip OpenBot
#   sudo ./install.sh --no-bridge        skip the agent bridge
#   sudo ./install.sh --no-runner        skip both runners
#   sudo ./install.sh --skip 60,70       skip steps by number
#
# Re-running is safe: every step checks whether it already did its job, and
# every secret that exists is kept.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/stack/install/_lib.sh"
source "${HOST_ENV}"

SKIP=""
DO_OPENBOT=1
DO_BRIDGE=1
DO_RUNNERS=1
DO_TOOLING=1
while (( $# )); do
  case "$1" in
    --no-openbot) DO_OPENBOT=0; shift ;;
    --no-bridge)  DO_BRIDGE=0;  shift ;;
    --no-runner)  DO_RUNNERS=0; shift ;;
    --no-tooling) DO_TOOLING=0; shift ;;
    --skip=*)     SKIP="${SKIP},${1#--skip=}"; shift ;;
    --skip)       shift; SKIP="${SKIP},${1:-}"; shift ;;
    *)            die "unknown option: $1" ;;
  esac
done

skip_step() { [[ ",${SKIP}," == *",$1,"* ]]; }

run_step() {
  local num="$1" label="$2" script="$3"
  if skip_step "$num"; then
    warn "skipping ${label} (--skip ${num})"
    return 0
  fi
  echo
  printf '\033[1;35m########## %s ##########\033[0m\n' "${label}"
  bash "${script}"
}

need_root

chmod +x "${HERE}"/stack/install/*.sh "${HERE}"/stack/mirror/*.sh \
           "${HERE}"/stack/verify/*.sh "${HERE}"/stack/backup/*.sh \
           "${HERE}"/components/*/*.sh "${HERE}"/verify/*.sh 2>/dev/null || true

cat <<EOF

=================================================================
  oma-stack 1.0.0 — Forgejo + CI runner + OpenBot + agent bridge
=================================================================
EOF

# ---------------------------------------------------------------------------
# 1. The Forgejo + CI layer
# ---------------------------------------------------------------------------
run_step 10 "forgejo + runners" "${HERE}/stack/install.sh"

# ---------------------------------------------------------------------------
# 2. OpenBot
# ---------------------------------------------------------------------------
if (( DO_OPENBOT )) && [[ "${ENABLE_OPENBOT}" == "1" ]]; then
  run_step 20 "openbot" "${HERE}/components/openbot/install-openbot.sh"
else
  warn "skipping OpenBot"
fi

# ---------------------------------------------------------------------------
# 3. The agent bridge
# ---------------------------------------------------------------------------
if (( DO_BRIDGE )) && [[ "${ENABLE_AGENT_BRIDGE}" == "1" ]]; then
  run_step 30 "agent bridge" "${HERE}/components/agents/install-agents.sh"
else
  warn "skipping the agent bridge"
fi

# ---------------------------------------------------------------------------
# 4. Tooling
# ---------------------------------------------------------------------------
if (( DO_TOOLING )) && [[ "${ENABLE_TOOLING}" == "1" ]]; then
  run_step 40 "tooling" "${HERE}/components/tooling/install-tooling.sh"
else
  warn "skipping the tooling"
fi

# ---------------------------------------------------------------------------
# 5. The unified healthcheck
# ---------------------------------------------------------------------------
echo
printf '\033[1;35m########## health ##########\033[0m\n'
bash "${HERE}/verify/healthcheck.sh" || warn "the healthcheck reported problems — see the output above"

cat <<EOF

=================================================================
  oma-stack installed.

  Forgejo (CI + mirror + issues)  : ${FORGEJO_URL_FOR_DISPLAY}
  OpenBot (the agent surface)     : http://127.0.0.1:${OPENBOT_PORT}
  Agent bridge (AG-UI)            : http://127.0.0.1:${AGENT_BRIDGE_PORT}
  GitHub self-hosted runner        : ${GITHUB_RUNNER_NAME}

  Storage
    internal SSD (hot)             : ${BOOT_DATA}
    USB SATA (backups)             : ${BACKUP_ROOT} (keep ${BACKUP_RETENTION}, every ${BACKUP_INTERVAL_H}h)

  Next:
    1. Save the Forgejo admin password printed earlier.
    2. Add the Intelligence key and a model key:
         sudo nano ${CRED_DIR}/openbot.env
         sudo systemctl restart oma-openbot.service
    3. Put a GitHub PAT (repo scope) in ${GITHUB_TOKEN_FILE}, mode 0600
    4. Health:  sudo ${HERE}/verify/healthcheck.sh
    5. Docs:    ${HERE}/docs/RUNBOOK.md
=================================================================
EOF
