#!/usr/bin/env bash
# 50-always-on.sh — make the MacBook survive as an unattended CI box.
#
# A 2014 MacBook closes its lid when it is idle, and macOS-style sleep timers
# will happily kill a 4-hour CI job. These settings stop that.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/_lib.sh"
source "${HOST_ENV}"

need_root "$@"

if [[ "${ENABLE_ALWAYS_ON}" != "1" ]]; then
  log "ENABLE_ALWAYS_ON=0 — skipping"
  exit 0
fi

log "configuring logind"
install -d /etc/systemd/logind.conf.d
cat >/etc/systemd/logind.conf.d/00-oma-stack.conf <<CONF
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
CONF
ok "lid switch and idle suspend ignored"

log "installing the sleep inhibitor"
cat >/etc/systemd/system/ci-sleep-inhibitor.service <<UNIT
[Unit]
Description=Block suspend while the CI runner is active
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/bin/systemd-inhibit --what=sleep:idle --mode=block --who=ci --why="CI runner active"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now ci-sleep-inhibitor.service
ok "ci-sleep-inhibitor.service enabled"

if have omarchy && command -v omarchy >/dev/null 2>&1; then
  log "Omarchy detected — checking its own sleep switches"
  if omarchy toggle suspend >/dev/null 2>&1; then
    ok "omarchy suspend toggled off"
  else
    note "run manually if needed:  omarchy toggle suspend"
  fi
  [[ -f /etc/systemd/sleep.conf.d/omarchy-sleep-disabled.conf ]] && \
    ok "Omarchy sleep override present"
fi

# --- Docker resource ceiling ----------------------------------------------
if have docker; then
  log "capping docker memory at ${DOCKER_MEMORY_LIMIT} (the desktop needs the rest)"
  install -d /etc/docker
  if [[ -f /etc/docker/daemon.json ]]; then
    cp -a /etc/docker/daemon.json /etc/docker/daemon.json.bak
  fi
  cat >/etc/docker/daemon.json <<JSON
{
  "memory": "${DOCKER_MEMORY_LIMIT}",
  "swap": false,
  "data-root": "${DOCKER_DATA_ROOT}"
}
JSON
  systemctl restart docker
  ok "docker memory limited to ${DOCKER_MEMORY_LIMIT}, data-root ${DOCKER_DATA_ROOT}"
fi

# --- Log rotation ----------------------------------------------------------
log "bounding log growth on the 128 GB SSD"
cat >/etc/logrotate.d/oma-stack <<ROT
/var/lib/forgejo/log/*.log {
  daily
  rotate 7
  compress
  missingok
  notifempty
  copytruncate
}
ROT
ok "logrotate rule installed"

echo
ok "always-on configuration complete"
