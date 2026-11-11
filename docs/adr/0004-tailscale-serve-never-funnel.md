# ADR-0004: Tailscale with serve, never funnel

- **Status:** accepted
- **Date:** 2026-11-11
- **Deciders:** MartinMayday (owner), Qoder (CTO/architecture)

## Context

The owner wants connectivity between five personal devices — iPhone, iPad,
MacBook Pro "oma", Mac Studio M1 Max and the Proxmox host "hl-pve01" —
with nothing exposed to the public internet and nothing on the LAN.

The alternatives all fail one of those two conditions. A public domain with
a reverse proxy puts the box on the internet. Port forwarding does the same
without even the certificate. Leaving the services on the LAN makes them
reachable from every device on every network the laptop has joined.

The kit therefore needs a private mesh that authenticates the owner's own
devices and refuses everything else.

## Decision

Tailscale, with `tailscale serve` only. `tailscale funnel` publishes to the
entire public internet and is never invoked; the harness fails if any script
calls it (`tests/harness.sh`).

Every service keeps a loopback bind, and `tailscaled` proxies the tailnet
endpoint to it:

- Forgejo on `127.0.0.1:3000`, published as
  `https://oma.<tailnet>.ts.net/`.
- The agent bridge on `0.0.0.0:8765` but allowlisted
  ([ADR-0003](0003-bridge-peer-cidr-allowlist.md)), published as
  `https://oma.<tailnet>.ts.net:9443/`.
- OpenBot on `127.0.0.1:3001`, published on the tailnet address rather than
  through serve ([ADR-0006](0006-openbot-published-on-tailnet-address.md)).

The canonical `tailscale up` command is persisted at
`/etc/oma-stack/tailscale-up.cmd`, because `tailscale up` flags are not
persisted between runs and a later bare `tailscale up` resets them to the
defaults.

The access policy is grants-only
(`components/tailscale/tailnet-policy.json`), with no `acls` key, which
flips the tailnet from the default allow-all to deny-by-default.

## Consequences

### Good

- Nothing is published to the internet, and no port is forwarded on the
  home router.
- One tailnet identity replaces three bad options: router port forwarding, a
  second VPN on the router, and LAN exposure.
- The policy file grants exactly four ports on the server and nothing else
  once it is saved.
- `oma serve refresh` re-publishes the whole stack idempotently, after a
  rename, an address change or a manual edit.

### Bad

- Five devices have to be signed in to the tailnet and kept signed in.
- The policy file has to be pasted into the admin console by hand; there is
  no CLI that applies it.
- Multi-port publishing needs tailscale 1.52 or newer, so an old client
  loses the bridge endpoint.

### Neutral

- The tailnet needs MagicDNS and HTTPS enabled in the admin console; without
  them there is no name and no certificate to publish.
- `serve --bg` is mandatory: without it the command runs in the foreground
  and never returns, which would block the `Type=oneshot` unit.
- The four untagged client devices still expire their node keys every 180
  days and must be reauthorized; the tagged server does not.
- The bridge's tailnet publish only works because
  [ADR-0003](0003-bridge-peer-cidr-allowlist.md) allows `100.64.0.0/10`.

## Alternatives considered

- **A public domain with a reverse proxy** — costs money every year and
  exposes the box to the internet, which is the one thing the owner does
  not want.
- **A VPN appliance on the router** — one more device to run, maintain and
  patch, for the same private mesh Tailscale already provides.
- **`tailscale funnel`** — publishes the services to the entire public
  internet, which is the opposite of the requirement.
