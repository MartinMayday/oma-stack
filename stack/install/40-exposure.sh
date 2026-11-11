#!/usr/bin/env bash
# 40-exposure.sh — decide how the MacBook is reachable.
#
#   none      LAN only. Forgejo on http://<lan-ip>:3000. Simplest, safest.
#   tailscale tailnet only. Best default if the laptop moves between networks.
#   caddy     public https on your own domain. Needs DNS + ports 80/443 open.
#
# Nothing here is exposed to the internet by default. Forgejo is reachable on
# the LAN either way (it binds 127.0.0.1; this script opens the front door).

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/_lib.sh"
source "${HOST_ENV}"

need_root "$@"

case "${EXPOSE_MODE}" in
  none)
    log "EXPOSE_MODE=none — LAN only"
    # Bind on all interfaces so the LAN can reach it.
    sed -i "s|^HTTP_ADDR = .*|HTTP_ADDR = 0.0.0.0|" /etc/forgejo/app.ini
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -n "$ip" ]]; then
      sed -i "s|^ROOT_URL = .*|ROOT_URL = http://${ip}:3000/|" /etc/forgejo/app.ini
      sed -i "s|^DOMAIN = .*|DOMAIN = ${ip}|" /etc/forgejo/app.ini
      sed -i "s|^SSH_DOMAIN = .*|SSH_DOMAIN = ${ip}|" /etc/forgejo/app.ini
    fi
    systemctl restart forgejo.service
    note "Forgejo is at http://${ip:-<lan-ip>}:3000 from the LAN"
    note "SSH is at ssh://git@${ip:-<lan-ip>}:2222"
    note "To open it up later: set EXPOSE_MODE in host.env and re-run this script"
    ;;

  tailscale)
    log "EXPOSE_MODE=tailscale"
    pkg_install tailscale
    systemctl enable --now tailscaled

    if ! tailscale status >/dev/null 2>&1; then
      note "tailscale is not logged in yet. Run:"
      note "  sudo tailscale up"
      note "  (it prints a login URL — open it, then re-run this script)"
      exit 0
    fi

    TS_NAME=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//')
    [[ -n "$TS_NAME" ]] || { warn "could not read the tailscale hostname"; exit 1; }
    ok "tailnet name: ${TS_NAME}"

    tailscale serve --bg --https=443 "http://127.0.0.1:3000" || \
      warn "tailscale serve failed (older CLI: 'tailscale serve 3000')"
    ok "Forgejo served at https://${TS_NAME}"

    # The Forgejo config must advertise the same URL or links break, and it
    # should only listen on loopback because tailscale proxies to it.
    sed -i "s|^HTTP_ADDR = .*|HTTP_ADDR = 127.0.0.1|" /etc/forgejo/app.ini
    sed -i "s|^ROOT_URL = .*|ROOT_URL = https://${TS_NAME}/|" /etc/forgejo/app.ini
    sed -i "s|^DOMAIN = .*|DOMAIN = ${TS_NAME}|" /etc/forgejo/app.ini
    sed -i "s|^SSH_DOMAIN = .*|SSH_DOMAIN = ${TS_NAME}|" /etc/forgejo/app.ini
    systemctl restart forgejo.service
    ok "app.ini updated to advertise https://${TS_NAME}"
    note "Remember to update FORGEJO_DOMAIN in host.env to: ${TS_NAME}"
    ;;

  caddy)
    log "EXPOSE_MODE=caddy"
    [[ -n "${FORGEJO_DOMAIN_CADDY}" ]] || die "set FORGEJO_DOMAIN_CADDY in host.env"
    [[ -n "${FORGEJO_ACME_EMAIL}" ]] || die "set FORGEJO_ACME_EMAIL in host.env"
    pkg_install caddy
    cat >/etc/caddy/Caddyfile <<CADDY
${FORGEJO_DOMAIN_CADDY} {
  reverse_proxy 127.0.0.1:3000
}
CADDY
    sed -i "s|^HTTP_ADDR = .*|HTTP_ADDR = 127.0.0.1|" /etc/forgejo/app.ini
    sed -i "s|^ROOT_URL = .*|ROOT_URL = https://${FORGEJO_DOMAIN_CADDY}/|" /etc/forgejo/app.ini
    sed -i "s|^DOMAIN = .*|DOMAIN = ${FORGEJO_DOMAIN_CADDY}|" /etc/forgejo/app.ini
    sed -i "s|^SSH_DOMAIN = .*|SSH_DOMAIN = ${FORGEJO_DOMAIN_CADDY}|" /etc/forgejo/app.ini
    systemctl restart forgejo.service
    systemctl enable --now caddy
    ok "Caddy serving ${FORGEJO_DOMAIN_CADDY} (cert issuance needs DNS + 80/443 open)"
    ;;

  *)
    die "unknown EXPOSE_MODE='${EXPOSE_MODE}' (none|tailscale|caddy)"
    ;;
esac
