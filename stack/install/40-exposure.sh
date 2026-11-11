#!/usr/bin/env bash
# 40-exposure.sh — decide how the MacBook is reachable.
#
#   tailnet  127.0.0.1 only.  The tailnet component publishes it at
#            https://<host>.<tailnet>.ts.net/.  Nothing on the LAN.
#   none     127.0.0.1 only and nothing publishes it.  This box only.
#   lan      0.0.0.0, reachable at http://<lan-ip>:3000/ from the LAN.
#   caddy    public https on your own domain.  Needs DNS + ports 80/443 open.
#
# Nothing here is exposed to the internet by default, and the default keeps
# the box off the LAN too: the tailnet is the way in.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/_lib.sh"
source "${HOST_ENV}"

need_root "$@"

# `tailscale` was the old name of `tailnet`.
EXPOSE_MODE="${EXPOSE_MODE/tailscale/tailnet}"

set_http_addr() {
  sed -i "s|^HTTP_ADDR = .*|HTTP_ADDR = ${1}|" /etc/forgejo/app.ini
}

case "${EXPOSE_MODE}" in
  none)
    log "EXPOSE_MODE=none — this box only"
    # Loopback only, and nothing publishes it.
    set_http_addr 127.0.0.1
    sed -i "s|^ROOT_URL = .*|ROOT_URL = http://127.0.0.1:${FORGEJO_PORT:-3000}/|" /etc/forgejo/app.ini
    sed -i "s|^DOMAIN = .*|DOMAIN = 127.0.0.1|" /etc/forgejo/app.ini
    systemctl restart forgejo.service
    note "Forgejo answers on http://127.0.0.1:${FORGEJO_PORT:-3000} and nowhere else"
    note "To open it up later: set EXPOSE_MODE in host.env and re-run this script"
    ;;

  lan)
    log "EXPOSE_MODE=lan — reachable from the LAN"
    # Bind on all interfaces so the LAN can reach it.  This is the one mode
    # that puts Forgejo where other devices on the network can get to it.
    set_http_addr 0.0.0.0
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -n "$ip" ]]; then
      sed -i "s|^ROOT_URL = .*|ROOT_URL = http://${ip}:${FORGEJO_PORT:-3000}/|" /etc/forgejo/app.ini
      sed -i "s|^DOMAIN = .*|DOMAIN = ${ip}|" /etc/forgejo/app.ini
      sed -i "s|^SSH_DOMAIN = .*|SSH_DOMAIN = ${ip}|" /etc/forgejo/app.ini
    fi
    systemctl restart forgejo.service
    note "Forgejo is at http://${ip:-<lan-ip>}:${FORGEJO_PORT:-3000} from the LAN"
    note "SSH is at ssh://git@${ip:-<lan-ip>}:2222"
    note "To close it again: set EXPOSE_MODE=tailnet or none and re-run this script"
    ;;

  tailnet)
    log "EXPOSE_MODE=tailnet — published on the tailnet"
    # Forgejo listens on loopback only; tailscaled proxies the tailnet
    # HTTPS endpoint to it.  The tailnet component owns the publishing and
    # rewrites ROOT_URL once the node has a name, so this only sets the
    # provisional value.
    set_http_addr 127.0.0.1
    sed -i "s|^ROOT_URL = .*|ROOT_URL = http://127.0.0.1:${FORGEJO_PORT:-3000}/|" /etc/forgejo/app.ini
    systemctl restart forgejo.service
    note "Forgejo listens on 127.0.0.1:${FORGEJO_PORT:-3000} only"
    note "The tailnet publishes it once you are logged in:  sudo oma serve refresh"
    ;;

  caddy)
    log "EXPOSE_MODE=caddy"
    [[ -n "${FORGEJO_DOMAIN_CADDY}" ]] || die "set FORGEJO_DOMAIN_CADDY in host.env"
    [[ -n "${FORGEJO_ACME_EMAIL}" ]] || die "set FORGEJO_ACME_EMAIL in host.env"
    pkg_install caddy
    cat >/etc/caddy/Caddyfile <<CADDY
${FORGEJO_DOMAIN_CADDY} {
  reverse_proxy 127.0.0.1:${FORGEJO_PORT:-3000}
}
CADDY
    set_http_addr 127.0.0.1
    sed -i "s|^ROOT_URL = .*|ROOT_URL = https://${FORGEJO_DOMAIN_CADDY}/|" /etc/forgejo/app.ini
    sed -i "s|^DOMAIN = .*|DOMAIN = ${FORGEJO_DOMAIN_CADDY}|" /etc/forgejo/app.ini
    sed -i "s|^SSH_DOMAIN = .*|SSH_DOMAIN = ${FORGEJO_DOMAIN_CADDY}|" /etc/forgejo/app.ini
    systemctl restart forgejo.service
    systemctl enable --now caddy
    ok "Caddy serving ${FORGEJO_DOMAIN_CADDY} (cert issuance needs DNS + 80/443 open)"
    ;;

  *)
    die "unknown EXPOSE_MODE='${EXPOSE_MODE}' (none|tailnet|lan|caddy)"
    ;;
esac
