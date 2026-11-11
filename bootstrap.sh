#!/usr/bin/env bash
# bootstrap.sh — install oma-stack with one command.
#
#   curl -fsSL https://raw.githubusercontent.com/MartinMayday/oma-stack/main/bootstrap.sh | sudo bash
#
#   git clone https://github.com/MartinMayday/oma-stack.git
#   cd oma-stack && sudo ./bootstrap.sh
#
# The second form runs the checkout you already have.  The first form clones
# into /opt/oma-stack and runs the same installer.
#
# Options are passed straight through to install.sh:
#   ... | sudo bash -s -- --no-openbot

set -euo pipefail

REPO_URL="${OMA_STACK_REPO:-https://github.com/MartinMayday/oma-stack.git}"
REF="${OMA_STACK_REF:-main}"
INSTALL_DIR="${OMA_STACK_DIR:-/opt/oma-stack}"
CONFIG_DIR="/etc/oma-stack"
HOST_ENV="${CONFIG_DIR}/host.env"

die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m[ ok]\033[0m %s\n' "$*"; }
log()  { printf '\033[1;34m[==>]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
note() { printf '       %s\n' "$*"; }

[[ "$(id -u)" -eq 0 ]] || die "run this as root: sudo bash bootstrap.sh"

cat <<'EOF'

=================================================================
  oma-stack — Forgejo + CI runner + OpenBot + agent bridge
  target: Omarchy / Arch, x86_64 (Intel MacBook Pro)
=================================================================

EOF

# ---------------------------------------------------------------------------
# 1. Is this the right machine?
# ---------------------------------------------------------------------------
if [[ "$(uname -m)" != "x86_64" ]]; then
  die "this stack targets x86_64 (Intel). You are on $(uname -m)."
fi
ok "architecture x86_64"

if command -v pacman >/dev/null 2>&1; then
  ok "distro: $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)"
else
  warn "no pacman found — this stack is built for Arch/Omarchy."
  note "continuing, but the package steps will not work."
fi

if command -v systemctl >/dev/null 2>&1; then
  ok "systemd present"
else
  die "systemd is required — this stack installs services, not processes."
fi

# ---------------------------------------------------------------------------
# 2. Get the code
# ---------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"

if [[ -n "${HERE}" && -f "${HERE}/install.sh" ]]; then
  SRC="${HERE}"
  ok "running from the checkout at ${SRC}"
else
  if ! command -v git >/dev/null 2>&1; then
    log "installing git"
    pacman -S --needed --noconfirm git
  fi
  install -d -m 0755 "$(dirname "${INSTALL_DIR}")"
  if [[ -d "${INSTALL_DIR}/.git" ]]; then
    log "updating ${INSTALL_DIR}"
    git -C "${INSTALL_DIR}" fetch --quiet origin "${REF}" || warn "fetch failed — keeping what is there"
    git -C "${INSTALL_DIR}" checkout --quiet "${REF}" || warn "checkout failed — keeping what is there"
    git -C "${INSTALL_DIR}" pull --quiet --ff-only 2>/dev/null || true
  else
    [[ -e "${INSTALL_DIR}" ]] && die "${INSTALL_DIR} exists and is not a git checkout — move it aside"
    log "cloning ${REPO_URL} into ${INSTALL_DIR}"
    git clone --depth 1 --branch "${REF}" "${REPO_URL}" "${INSTALL_DIR}"
  fi
  SRC="${INSTALL_DIR}"
  ok "installed to ${SRC}"
fi

# ---------------------------------------------------------------------------
# 3. The config survives an update
# ---------------------------------------------------------------------------
install -d -m 0711 "${CONFIG_DIR}"
if [[ -f "${HOST_ENV}" ]]; then
  ok "keeping the existing configuration at ${HOST_ENV}"
else
  install -m 0600 "${SRC}/config/host.env" "${HOST_ENV}"
  ok "configuration written to ${HOST_ENV} — this is the file you edit"
fi

# ---------------------------------------------------------------------------
# 4. Run the installer
# ---------------------------------------------------------------------------
log "running the installer"
cd "${SRC}"
exec bash "${SRC}/install.sh" "$@"
