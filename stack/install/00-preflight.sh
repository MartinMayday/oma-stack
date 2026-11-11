#!/usr/bin/env bash
# 00-preflight.sh — check the host before touching anything.
#
# This box is a 2014 MacBook Pro: dual-core i5, 8 GB RAM, 128 GB internal SSD,
# 512 GB SD card, 4 TB USB SATA. This script verifies that reality and prints
# what will happen. It changes nothing.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/_lib.sh"
source "${HOST_ENV}"

log "=== preflight ==="

# --- OS -------------------------------------------------------------------
if have pacman; then
  ok "Arch-family distro: $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)"
elif have apt-get; then
  ok "Debian-family distro: $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)"
else
  warn "unknown distro — continuing, but the install scripts assume Arch/Debian"
fi

if [[ "$(uname -m)" != "x86_64" ]]; then
  die "this package targets x86_64 (Intel). You are on $(uname -m)."
fi
ok "architecture x86_64"

# --- CPU / RAM ------------------------------------------------------------
CPU_CORES=$(nproc)
RAM_GB=$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)
note "CPU: ${CPU_CORES} logical cores"
note "RAM: ${RAM_GB} GB"
if (( CPU_CORES <= 2 )); then
  note "-> low core count: RUNNER_CAPACITY stays at 1 (set in host.env)"
fi
if (( RAM_GB < 9 )); then
  note "-> under 9 GB RAM: docker runner label stays OFF, host label only"
fi

# --- Disks ----------------------------------------------------------------
echo
log "block devices"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT | sed 's/^/  /' || true

for d in "$USB_DISK" "$SCRATCH_DISK"; do
  echo
  if mountpoint -q "$d"; then
    ok "$d is mounted"
    df -h "$d" | tail -1 | sed 's/^/  /'
  else
    warn "$d is NOT mounted"
    note "create it with a UUID-based fstab entry, e.g.:"
    note "  blkid                       # find UUID"
    note "  echo 'UUID=<uuid> ${d} ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab"
    note "  sudo mkdir -p ${d} && sudo mount ${d}"
  fi
done

# --- Required tools -------------------------------------------------------
echo
log "required commands"
for c in git curl jq openssl tar systemctl; do
  if have "$c"; then ok "$c"; else warn "$c missing (will be installed)"; fi
done
if have docker; then
  ok "docker present"
  docker --version | sed 's/^/  /'
  systemctl is-active --quiet docker && ok "docker service active" \
    || warn "docker service not active"
else
  note "docker not installed (only needed for the optional docker runner label)"
fi

# --- Git identity ---------------------------------------------------------
echo
if have git; then
  git config --global user.name  >/dev/null 2>&1 && ok "git user.name = $(git config --global user.name)"  || warn "git user.name not set"
  git config --global user.email >/dev/null 2>&1 && ok "git user.email = $(git config --global user.email)" || warn "git user.email not set"
fi

# --- Network --------------------------------------------------------------
echo
if curl -fsS -o /dev/null --max-time 5 https://github.com; then
  ok "github.com reachable"
else
  warn "github.com NOT reachable — check network / proxy"
fi

# --- Port check -----------------------------------------------------------
echo
for p in 3000 2222; do
  if ss -ltn "sport = :$p" 2>/dev/null | grep -q LISTEN; then
    warn "port $p already in use"
  else
    ok "port $p free"
  fi
done

echo
log "preflight complete — review the notes above, then run ./install.sh"
