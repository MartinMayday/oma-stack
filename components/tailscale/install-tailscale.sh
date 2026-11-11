#!/usr/bin/env bash
# install-tailscale.sh — put the box on your private tailnet.
#
# Nothing is exposed to the public internet.  Every service keeps its
# loopback bind and tailscaled proxies the tailnet HTTPS endpoint to it.
# This is `tailscale serve`, never `tailscale funnel`.
#
#   iPhone      the Tailscale app, signed in to the same tailnet
#   iPad        the same
#   mac-studio  the same (the App Store build and the standalone CLI
#               cannot run at the same time)
#   hl-pve01    tailscale in the Proxmox host or in a container on it
#
# Headless machines can be logged in with a pre-auth key:
#   TAILSCALE_AUTHKEY="tskey-auth-..." in /etc/oma-stack/host.env
# Without one, the installer prints a login URL and you finish it by hand.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
source "${ROOT}/stack/install/_lib.sh"
source "${HOST_ENV}"

need_root "$@"

[[ "${ENABLE_TAILSCALE:-0}" == "1" ]] || { log "ENABLE_TAILSCALE=0 — skipping"; exit 0; }

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# 1. The daemon
# ---------------------------------------------------------------------------
log "installing tailscale"
if have tailscale; then
  ok "tailscale $(tailscale version 2>/dev/null | head -1)"
else
  if have pacman; then
    pacman -S --needed --noconfirm tailscale
  else
    warn "no pacman — install tailscale yourself: https://tailscale.com/download/linux"
    exit 1
  fi
  ok "tailscale installed"
fi

systemctl enable --now tailscaled.service
ok "tailscaled is running"

# ---------------------------------------------------------------------------
# 2. Log in
# ---------------------------------------------------------------------------
# A tag and a pre-auth key do not go together: the key carries its own tags,
# and the CLI refuses the pair.  With a key, the key must be tagged; with a
# browser login, the tag can be claimed here.
TS_UP_ARGS=(
  --hostname="${TAILSCALE_HOSTNAME:-oma}"
  --accept-dns="${TAILSCALE_ACCEPT_DNS:-1}"
  --ssh="${TAILSCALE_SSH:-0}"
)

if [[ -n "${TAILSCALE_TAGS:-}" && -z "${TAILSCALE_AUTHKEY:-}" ]]; then
  TS_UP_ARGS+=(--advertise-tags="${TAILSCALE_TAGS}")
elif [[ -n "${TAILSCALE_TAGS:-}" ]]; then
  note "the pre-auth key has to carry the tag ${TAILSCALE_TAGS} itself."
  note "a tag cannot be added on top of a key login."
fi

# `tailscale up` flags are not persisted between runs, and a later bare
# `tailscale up` resets them to the defaults.  The canonical command is kept
# on disk so it can be re-applied with one command.  It is built from the
# arguments this installer actually used, so it never claims a tag the
# pre-auth key was supposed to carry.
{
  echo "# The canonical \`tailscale up\` for this box.  Re-apply it with:"
  echo "#   bash /etc/oma-stack/tailscale-up.cmd"
  echo "#"
  echo "# \`tailscale up\` flags are not persisted between runs, and a later bare"
  echo "# \`tailscale up\` resets them to the defaults.  This file puts the node"
  echo "# back the way the installer left it."
  if [[ -n "${TAILSCALE_TAGS:-}" && -n "${TAILSCALE_AUTHKEY:-}" ]]; then
    echo "#"
    echo "# The tag is not on this command: it travels with the pre-auth key, and"
    echo "# the CLI refuses --advertise-tags together with --auth-key.  To"
    echo "# re-authenticate with a key, use one that already carries"
    echo "# ${TAILSCALE_TAGS}:"
    echo "#   tailscale up --auth-key=<key> --hostname=${TAILSCALE_HOSTNAME:-oma} \\"
    echo "#     --accept-dns=${TAILSCALE_ACCEPT_DNS:-1} --ssh=${TAILSCALE_SSH:-0}"
  fi
  printf 'tailscale up'
  for arg in "${TS_UP_ARGS[@]}"; do printf ' %q' "${arg}"; done
  printf '\n'
} >/etc/oma-stack/tailscale-up.cmd
chmod 0600 /etc/oma-stack/tailscale-up.cmd

already_in="$(tailscale status --json 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print("no"); raise SystemExit
print("yes" if (d.get("BackendState") in ("Running","NeedsLogin") and d.get("Self")) else "no")
' 2>/dev/null || echo "no")"

if [[ "${already_in}" == "yes" ]]; then
  ok "already logged in"
else
  if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
    log "logging in with the pre-auth key"
    if tailscale up "${TS_UP_ARGS[@]}" --auth-key="${TAILSCALE_AUTHKEY}" >/tmp/oma-ts-up.log 2>&1; then
      ok "logged in"
    else
      warn "tailscale up failed:"
      tail -5 /tmp/oma-ts-up.log | sed 's/^/    /'
    fi
  else
    log "starting the login — it will print a URL"
    # `tailscale up` blocks while it waits for the browser confirmation, so
    # it runs in the background and we surface the URL it prints.
    ( tailscale up "${TS_UP_ARGS[@]}" >/tmp/oma-ts-up.log 2>&1 & ) || true
    sleep 4
    URL="$(grep -oE 'https://login\.tailscale\.com/[a-z0-9]+/[a-z0-9]+' /tmp/oma-ts-up.log 2>/dev/null | head -1)"
    if [[ -n "${URL}" ]]; then
      note "open this on any of your devices:"
      printf '\n    %s%s%s\n' "${BOLD:-}" "${URL}" "${RESET:-}" 2>/dev/null || printf '\n    %s\n' "${URL}"
      note "then run:  sudo oma serve refresh"
    else
      note "run:  sudo tailscale up   and follow the URL it prints"
    fi
  fi
fi

# The tag can only be claimed once the policy that owns it is saved in the
# admin console.  Log in first and the CLI refuses the tag: the node comes
# up untagged, keeps a 180-day key, and is not covered by the
# `tag:oma-server` grant — `autogroup:self` never matches a tagged device,
# and an untagged node is not covered by it either.
if [[ -n "${TAILSCALE_TAGS:-}" ]]; then
  GOT_TAG="$(tailscale status --json 2>/dev/null | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("no"); raise SystemExit
tags = ((d.get("Self") or {}).get("Tags")) or []
print("yes" if tags else "no")
' 2>/dev/null || echo "no")"

  if [[ "${GOT_TAG}" == "yes" ]]; then
    ok "the node is tagged ${TAILSCALE_TAGS}"
  else
    warn "the node is NOT tagged ${TAILSCALE_TAGS}."
    note "the policy that owns the tag has to be saved first:"
    note "    paste /etc/oma-stack/tailnet-policy.json into the Tailscale"
    note "    admin console (Settings -> Access controls)"
    note "then claim the tag:"
    note "    bash /etc/oma-stack/tailscale-up.cmd"
    note "until then the node keeps a 180-day key and the tailnet policy"
    note "does not cover it."
  fi
fi

# ---------------------------------------------------------------------------
# 3. Publish the stack on the tailnet
# ---------------------------------------------------------------------------
log "installing the serve unit"
cat >/etc/systemd/system/oma-tailscale-serve.service <<UNIT
[Unit]
Description=oma-stack — publish the stack on the tailnet
After=network-online.target tailscaled.service forgejo.service oma-openbot.service
Wants=network-online.target
Requires=tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${ROOT}/components/tailscale/serve-refresh.sh
ExecReload=${ROOT}/components/tailscale/serve-refresh.sh

[Install]
WantedBy=multi-user.target
UNIT
chmod 0755 "${HERE}/serve-refresh.sh"
systemctl daemon-reload
systemctl enable oma-tailscale-serve.service >/dev/null 2>&1 || true

if tailscale status --json >/dev/null 2>&1; then
  systemctl restart oma-tailscale-serve.service || warn "the serve unit reported a problem"
else
  note "not logged in yet — the serve unit will publish once you are"
fi

# ---------------------------------------------------------------------------
# 4. Tell the operator what is left
# ---------------------------------------------------------------------------
install -m 0644 "${HERE}/tailnet-policy.json" /etc/oma-stack/tailnet-policy.json

cat <<EOF

  The tailnet name of this box:
    tailscale status --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["Self"]["DNSName"])'

  Publish or refresh the services:
    sudo oma serve refresh

  The access policy for your tailnet is written to:
    /etc/oma-stack/tailnet-policy.json
  Paste it into the Tailscale admin console (Settings -> Access controls)
  BEFORE you claim the tag.  The policy owns the tag: without it the
  login is refused the tag, the node keeps a 180-day key, and the
  tailnet policy does not cover it.

  Saving it turns the tailnet from allow-all to deny-by-default: after that,
  only the ports it lists are reachable.

  On every other device, install the Tailscale app and sign in to the same
  tailnet.  Then Forgejo, OpenBot and the bridge are reachable by their
  tailnet names — and by nothing else.

EOF
