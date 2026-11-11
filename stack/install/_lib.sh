#!/usr/bin/env bash
# Shared helpers. Sourced by every script in the package.

set -euo pipefail

log()  { printf '\033[1;34m[==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }
note() { printf '       %s\n' "$*"; }

need_root() {
  [[ "$(id -u)" -eq 0 ]] || die "run this as root: sudo $0 $*"
}

have() { command -v "$1" >/dev/null 2>&1; }

# Confirm a systemd unit is mounted and the disk behind it is really there.
require_mount() {
  local dir="$1" label="$2"
  if ! mountpoint -q "$dir"; then
    die "$label: $dir is not a mounted filesystem.
     Check it:  lsblk -f ; mount $dir
     Until it is mounted, do NOT start forgejo (it would write to the root disk)."
  fi
  ok "$label mounted at $dir"
}

# Wait until an HTTP URL answers with 200.
wait_http() {
  local url="$1" tries="${2:-30}"
  for _ in $(seq 1 "$tries"); do
    if curl -fsS -o /dev/null --max-time 3 "$url"; then return 0; fi
    sleep 1
  done
  return 1
}

# Random hex secret of N characters.
random_hex() { local n="${1:-48}"; openssl rand -hex $((n / 2)); }

# Locate the forgejo binary. The Arch package installs it to /usr/bin/forgejo;
# the upstream tarball install puts it in /usr/local/bin.
FORGEJO_BIN="$(command -v forgejo 2>/dev/null || true)"
[[ -z "$FORGEJO_BIN" && -x /usr/local/bin/forgejo ]] && FORGEJO_BIN=/usr/local/bin/forgejo
[[ -z "$FORGEJO_BIN" && -x /usr/bin/forgejo ]] && FORGEJO_BIN=/usr/bin/forgejo
export FORGEJO_BIN

# Resolve the runner scratch directory.
# The SD card is nice to have but not required — when it is not inserted the
# runner falls back to the internal SSD so CI keeps working.
runner_workdir() {
  if [[ -n "${SCRATCH_DISK:-}" ]] && mountpoint -q "$SCRATCH_DISK" 2>/dev/null; then
    printf '%s' "${SCRATCH_WORK:-${SCRATCH_DISK}/act-work}"
  else
    printf '%s' "/var/cache/forgejo-runner/work"
  fi
}

# ---------------------------------------------------------------------------
# The one config file
# ---------------------------------------------------------------------------
# oma-stack has exactly one config file, and every script reads it. It lives at
# the repository root while the kit is a checkout, and at /etc/oma-stack/host.env
# once it is installed. The stack/ layer sits one directory deep, so the
# candidates below cover both layouts without any script having to know where
# it was invoked from.
host_env_path() {
  local c
  for c in "${OMA_CONFIG:-}" \
           "/etc/oma-stack/host.env" \
           "${HERE:-.}/../../config/host.env" \
           "${HERE:-.}/../config/host.env"; do
    [[ -n "$c" && -f "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

HOST_ENV="$(host_env_path || true)"
[[ -n "${HOST_ENV}" ]] || die "host.env not found — expected it at config/host.env or /etc/oma-stack/host.env"
export HOST_ENV

# Run a command as another user, without assuming sudo is installed.
# (Minimal Arch installs often lack sudo.)
as_user() {
  local user="$1"; shift
  if have runuser; then
    runuser -u "$user" -- "$@"
  elif have sudo; then
    sudo -u "$user" "$@"
  else
    su -s /bin/bash "$user" -c "$(printf '%q ' "$@")"
  fi
}

pkg_install() {
  if have pacman; then
    pacman -S --needed --noconfirm "$@"
  elif have apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  else
    die "no supported package manager found (need pacman or apt-get)"
  fi
}
