#!/usr/bin/env bash
# serve-refresh.sh — publish the stack on the tailnet.
#
# Forgejo and the bridge keep a loopback bind, and tailscaled proxies the
# tailnet HTTPS endpoint to it.  The bridge is the exception: it binds
# 0.0.0.0 because the OpenBot container reaches it through the Docker
# bridge gateway, and it is gated by a CIDR allowlist instead (see
# docs/adr/0003-bridge-peer-cidr-allowlist.md).
#
# Nothing is exposed to the public internet: this is `tailscale serve`,
# never `tailscale funnel`.
#
#   https://oma.<tailnet>.ts.net          -> forgejo      127.0.0.1:3000
#   https://oma.<tailnet>.ts.net:9443     -> agent bridge 127.0.0.1:8765
#   http://<100.x.y.z>:3001               -> openbot      (its own port)
#
# OpenBot is the odd one out, and deliberately so.  OpenBot in single-user
# mode admits every request as one administrator with no sign-in, so upstream
# refuses to start when it is told about a *public* address — and a
# MagicDNS name is public to it, while a 100.x tailnet address is private.
# (server/src/config.ts, reachOf().)  So OpenBot is published on the tailnet
# address in plain HTTP — the tailnet transport is already encrypted — and
# that address is what goes into TRUSTED_ORIGINS.
#
# Run it by hand:  oma serve refresh
# It also runs at every boot, from oma-tailscale-serve.service.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
source "${ROOT}/stack/install/_lib.sh"
source "${HOST_ENV}"

have() { command -v "$1" >/dev/null 2>&1; }

[[ "${ENABLE_TAILSCALE:-0}" == "1" ]] || { log "tailscale is disabled — nothing to publish"; exit 0; }
have tailscale || die "tailscale is not installed"

# `tailscale` was the old name of `tailnet`.
EXPOSE_MODE="${EXPOSE_MODE:-tailnet}"
EXPOSE_MODE="${EXPOSE_MODE/tailscale/tailnet}"

# Forgejo is published on the tailnet only when EXPOSE_MODE says so.  In
# `lan` mode it already answers on the LAN under its own address, and in
# `caddy` mode the domain owns the name; in `none` mode nothing publishes it.
SERVE_FORGEJO=0
if [[ "${EXPOSE_MODE}" == "tailnet" && "${TAILSCALE_SERVE_FORGEJO:-1}" == "1" ]]; then
  SERVE_FORGEJO=1
fi

# Is the node actually logged in?  Without a login there is no tailnet name
# and no certificate, so there is nothing to serve.
if ! tailscale status --json >/tmp/oma-ts.json 2>/dev/null; then
  warn "tailscale is not logged in yet — run: sudo tailscale up"
  exit 0
fi

read -r TS_NAME TS_IP <<EOF
$(python3 -c '
import json
d = json.load(open("/tmp/oma-ts.json"))
self_ = d.get("Self") or {}
name = (self_.get("DNSName") or "").rstrip(".")
ips = self_.get("TailscaleIPs") or []
ip = ""
for candidate in ips:
    if ":" not in candidate:
        ip = candidate
        break
print(name, ip)
' 2>/dev/null || echo " ")
EOF

if [[ -z "${TS_NAME}" ]]; then
  warn "no MagicDNS name yet — enable HTTPS in the Tailscale admin console"
  exit 0
fi

log "publishing on ${TS_NAME}"

# ---------------------------------------------------------------------------
# 1. OpenBot — published on the tailnet address
# ---------------------------------------------------------------------------
# The compose file publishes 127.0.0.1.  A second publish on the tailnet
# address goes in an override file, so the base file stays free of anything
# tailnet-specific and the override can be deleted with one command.
if [[ "${TAILSCALE_PUBLISH_OPENBOT:-1}" == "1" && -n "${TS_IP}" ]]; then
  OVERRIDE="${ROOT}/components/openbot/docker-compose.override.yml"
  cat >"${OVERRIDE}" <<YAML
# Written by oma-stack — the tailnet publish of OpenBot.
# Delete this file to take OpenBot off the tailnet.
services:
  openbot:
    ports:
      - "${TS_IP}:${OPENBOT_PORT:-3001}:3001"
YAML

  # The origin has to be trusted, or the browser's Origin header is refused
  # and the app does not talk to its own API.
  OPENBOT_ENV="${CRED_DIR}/openbot.env"
  ORIGIN="http://${TS_IP}:${OPENBOT_PORT:-3001}"
  if [[ -f "${OPENBOT_ENV}" ]]; then
    CURRENT="$(grep -m1 '^TRUSTED_ORIGINS=' "${OPENBOT_ENV}" 2>/dev/null | cut -d= -f2- || true)"
    if [[ "${CURRENT}" != *"${ORIGIN}"* ]]; then
      NEW="${CURRENT:+${CURRENT},}${ORIGIN}"
      python3 - "${OPENBOT_ENV}" "${NEW}" <<'PY'
import sys
path, value = sys.argv[1], sys.argv[2]
lines = []
for line in open(path):
    if line.startswith("TRUSTED_ORIGINS="):
        lines.append("TRUSTED_ORIGINS=" + value + "\n")
    else:
        lines.append(line)
open(path, "w").writelines(lines)
PY
      ok "OpenBot now trusts ${ORIGIN}"
      ( cd "${ROOT}/components/openbot" && docker compose up -d --remove-orphans ) \
        || warn "could not restart OpenBot — run: oma serve refresh"
    fi
  fi
  ok "OpenBot published at ${ORIGIN}"
else
  rm -f "${ROOT}/components/openbot/docker-compose.override.yml"
fi

# ---------------------------------------------------------------------------
# 2. Forgejo — the tailnet name becomes its public address
# ---------------------------------------------------------------------------
# Forgejo builds its clone URLs and its redirects from ROOT_URL.  Left at
# 127.0.0.1, the links in the web UI point at the server's own loopback and
# the phone gets a URL it cannot use.
if [[ "${SERVE_FORGEJO}" == "1" ]]; then
  APP_INI="/etc/forgejo/app.ini"
  FORGEJO_PUBLIC="https://${TS_NAME}"
  if [[ -f "${APP_INI}" ]]; then
    WANT_ROOT="${FORGEJO_ROOT_URL:-${FORGEJO_PUBLIC}}/"
    if ! grep -qx "ROOT_URL = ${WANT_ROOT}" "${APP_INI}"; then
      sed -i "s|^ROOT_URL = .*|ROOT_URL = ${WANT_ROOT}|" "${APP_INI}"
      sed -i "s|^DOMAIN = .*|DOMAIN = ${TS_NAME}|" "${APP_INI}"
      sed -i "s|^SSH_DOMAIN = .*|SSH_DOMAIN = ${TS_NAME}|" "${APP_INI}"
      systemctl restart forgejo.service || warn "could not restart forgejo"
      ok "Forgejo answers at ${WANT_ROOT}"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 3. The tailnet HTTPS endpoints
# ---------------------------------------------------------------------------
# The serve syntax changed in tailscale 1.52 (October 2023).  The modern
# form serves a chosen HTTPS port and is the only one that can publish more
# than one service; the legacy form only ever used 443.  `--bg` is not
# optional: without it the command runs in the foreground and never returns.
serve_apply() {
  local https_port="$1" target="$2" label="$3"

  if tailscale serve --bg --https="${https_port}" "${target}" >/dev/null 2>&1; then
    ok "${label}: https://${TS_NAME}:${https_port} -> ${target}"
    return 0
  fi

  if [[ "${https_port}" == "443" ]] && tailscale serve --bg "${target}" >/dev/null 2>&1; then
    ok "${label}: https://${TS_NAME} -> ${target} (legacy syntax)"
    return 0
  fi

  warn "could not publish ${label} on port ${https_port} — your tailscale is too old"
  note "multi-port publishing needs tailscale >= 1.52 (pacman -Syu tailscale)"
  return 1
}

FAILED=0

if [[ "${SERVE_FORGEJO}" == "1" ]]; then
  serve_apply "${TAILSCALE_SERVE_HTTPS_PORT:-443}" "http://127.0.0.1:${FORGEJO_PORT:-3000}" "forgejo" || FAILED=1
fi

if [[ "${TAILSCALE_SERVE_BRIDGE:-1}" == "1" ]]; then
  serve_apply "${TAILSCALE_SERVE_BRIDGE_PORT:-9443}" "http://127.0.0.1:${AGENT_BRIDGE_PORT:-8765}" "agent bridge" || FAILED=1
fi

echo
tailscale serve status 2>&1 | sed 's/^/  /' || true

if (( FAILED )); then
  warn "some services were not published — see above"
  exit 1
fi
ok "the tailnet is serving"
