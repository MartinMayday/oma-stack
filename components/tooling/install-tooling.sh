#!/usr/bin/env bash
# install-tooling.sh — the small helpers the agents expect on the box.
#
# Nothing here is required by the stack. It exists so that an agent asked to
# "run the repo's validation" finds the tool rather than declaring it
# missing. Everything is installed for the operator's own account, never
# system-wide.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
source "${ROOT}/stack/install/_lib.sh"
source "${HOST_ENV}"

need_root "$@"

if [[ "${ENABLE_TOOLING}" != "1" ]]; then
  log "ENABLE_TOOLING=0 — skipping"
  exit 0
fi

OPERATOR="${SUDO_USER:-$(id -un)}"
if ! id -u "${OPERATOR}" >/dev/null 2>&1; then
  OPERATOR="$(id -un)"
fi
OPERATOR_HOME="$(getent passwd "${OPERATOR}" | cut -d: -f6)"

log "installing tooling for ${OPERATOR}"

# ---------------------------------------------------------------------------
# 1. python tooling
# ---------------------------------------------------------------------------
if [[ -n "${PIP_PACKAGES}" ]]; then
  if ! have pipx && ! have pip3; then
    log "installing pip"
    pkg_install python-pip
  fi
  PIP=""
  if have pipx; then
    PIP=(pipx install)
  elif have pip3; then
    PIP=(pip3 install --user)
  fi

  for pkg in ${PIP_PACKAGES}; do
    if "${PIP[@]}" --help >/dev/null 2>&1; then
      if as_user "${OPERATOR}" bash -lc "command -v ${pkg%% *} >/dev/null 2>&1"; then
        ok "${pkg} already installed"
        continue
      fi
      if as_user "${OPERATOR}" bash -lc "$(printf '%q ' "${PIP[@]}") ${pkg}" >/dev/null 2>&1; then
        ok "${pkg} installed"
      else
        warn "could not install ${pkg} — it may not exist on PyPI"
      fi
    fi
  done
fi

# ---------------------------------------------------------------------------
# 2. the Hermes persona library
# ---------------------------------------------------------------------------
if [[ -n "${HERMES_PERSONA_SOURCE}" ]]; then
  if have hermes; then
    log "installing the Hermes personas"
    count=0
    while IFS= read -r persona; do
      [[ -z "${persona}" ]] && continue
      name="$(basename "${persona}")"
      as_user "${OPERATOR}" bash -lc \
        "hermes profile install '${persona}' --name '${name}'" >/dev/null 2>&1 \
        && count=$((count+1))
    done < <(find "${HERMES_PERSONA_SOURCE}" -name '*.md' -type f 2>/dev/null)
    ok "${count} persona(s) installed"
  else
    warn "hermes is not on PATH — personas not installed"
    note "the persona source is ${HERMES_PERSONA_SOURCE}"
  fi
else
  note "HERMES_PERSONA_SOURCE is empty — no personas installed"
  note "point it at the agent-library catalog to install them:"
  note "  HERMES_PERSONA_SOURCE=\"${OPERATOR_HOME}/agent-library/catalogs/agents/bot-persona\""
fi

# ---------------------------------------------------------------------------
# 3. the validation helpers the repo ships
# ---------------------------------------------------------------------------
if [[ -d "${OPERATOR_HOME}/agent-library/Tools" ]]; then
  ok "the agent-library Tools/ directory is present at ${OPERATOR_HOME}/agent-library/Tools"
else
  note "no agent-library checkout at ${OPERATOR_HOME}/agent-library"
fi

ok "tooling done"
