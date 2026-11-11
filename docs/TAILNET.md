# TAILNET — the private tailnet

`oma-stack` is private by construction. The box runs Forgejo and OpenBot on
loopback, and the agent bridge behind a CIDR allowlist; the only way in from
another device is the tailnet Tailscale builds between your own machines. No
public DNS record, no forwarded port, no reverse proxy on the internet.

This is the operator guide for that tailnet: which devices join it, what the
kit publishes on it, which policy governs it, and what to do when a key
expires or a phone cannot open a page.

---

## 1. What the tailnet is for

One thing: it lets your five personal devices reach the services on `oma` and
nothing else. The box stays private on your LAN; your phone, tablet, other
laptop and the Proxmox host reach Forgejo, OpenBot and the bridge over a
WireGuard-encrypted mesh, authenticated by your tailnet identity.

**The threat model it replaces:** port forwarding on the home router (every
port exposed to the internet), a VPN on the router (a second identity system
to maintain), or services left on the LAN (reachable by every device on the
café wifi). The tailnet removes all three: **no public ports** — nothing
listens on a routable address, `tailscale serve` is tailnet-only and
`tailscale funnel` publishes to the entire internet and is never used here
([serve](https://tailscale.com/docs/features/tailscale-serve) ·
[funnel](https://tailscale.com/docs/features/tailscale-funnel)); **no LAN
exposure** — Forgejo and OpenBot keep their loopback binds (`127.0.0.1:3000`,
`127.0.0.1:3001`), with one deliberate exception: the bridge binds
`0.0.0.0:8765` because the OpenBot container reaches it through the Docker
bridge gateway, and it answers only callers inside `127.0.0.1/32`, `::1/128`,
`172.16.0.0/12` and `100.64.0.0/10`
([ADR-0003](adr/0003-bridge-peer-cidr-allowlist.md)); **single user, one
identity** — one tailnet, one owner, five devices, access control by a
grants-only policy file rather than a firewall ruleset, and WireGuard
encrypting the traffic underneath.

---

## 2. The five devices

| Device | Platform | What to install | Can | Cannot | Name |
|---|---|---|---|---|---|
| **MacBook Pro "oma"** | Omarchy / Arch (Linux x86_64) | The Arch `tailscale` package from repo `extra`, `tailscaled` as a systemd unit ([package](https://archlinux.org/packages/extra/x86_64/tailscale/)) | Runs the whole stack and publishes it; tagged `tag:oma-server` | Cannot be a public HTTPS endpoint — that is Funnel | `oma` |
| **iPhone** | iOS | The App Store app, signed in with the owner's identity | Exit node (carries the tailnet egress) | No CLI at all: no `tailscale serve`, no `tailscale up` flags. Never a subnet router — iOS is not a supported subnet-router platform ([exit nodes](https://tailscale.com/docs/features/exit-nodes) · [subnet routers](https://tailscale.com/docs/features/subnet-routers)) | `iphone` |
| **iPad** | iPadOS | Same as the iPhone | Exit node | Same as the iPhone: no CLI, never a subnet router | `ipad` |
| **Mac Studio M1 Max** | macOS | The **Standalone** variant (System Extension), which ships the CLI at `/Applications/Tailscale.app/Contents/MacOS/Tailscale` ([variants](https://tailscale.com/docs/concepts/macos-variants)) | Full CLI: `tailscale up`, `tailscale serve`, file serving | The App Store build and the Standalone build must never run together. The App Store build is sandboxed: no Funnel, no `tailscale ssh` CLI, no Tailscale SSH server | `mac-studio` |
| **Proxmox node "hl-pve01"** | Proxmox VE 8 (Debian 12 base) | Tailscale on the **PVE host**, not inside a guest ([Proxmox](https://tailscale.com/docs/integrations/proxmox)) | Reaches the Proxmox web UI on 8006 and the guests | An unprivileged LXC needs `/dev/net/tun` passthrough (`pct set <CTID> --dev0 /dev/net/tun`, `--features keyctl=1,nesting=1`) or userspace mode ([LXC](https://tailscale.com/docs/features/containers/lxc/lxc-unprivileged)). Never advertise the same LAN subnet from two nodes: overlapping routes cause conflicts, so if `hl-pve01` advertises the PVE LAN, `oma` must not | `hl-pve01` |

The machine name is set differently per platform: on Linux it comes from
`--hostname` on `tailscale up`, on mobile and macOS you edit it in the admin
console. MagicDNS names resolve as `<name>.<tailnet>.ts.net`
([MagicDNS](https://tailscale.com/docs/features/magicdns)).

---

## 3. Install on `oma`

### 3.1 What the kit runs

`components/tailscale/install-tailscale.sh` is step 45 of the installer. It
runs exactly this:

```bash
sudo pacman -S --needed --noconfirm tailscale     # Arch repo `extra`
sudo systemctl enable --now tailscaled.service
sudo tailscale up --hostname=oma --accept-dns=1 --ssh=0
sudo systemctl enable --now oma-tailscale-serve.service
```

`oma-tailscale-serve.service` is `Type=oneshot` with `RemainAfterExit=yes`;
it runs `components/tailscale/serve-refresh.sh` at boot and on
`systemctl reload`. The knobs live in `/etc/oma-stack/host.env`, section 13:

- `ENABLE_TAILSCALE=1` — `0` skips the component
- `TAILSCALE_HOSTNAME=oma` — the machine name in MagicDNS
- `TAILSCALE_ACCEPT_DNS=1` — let tailscale answer DNS system-wide
- `TAILSCALE_SSH=0` — the Tailscale SSH server (the box has real SSH)
- `TAILSCALE_TAGS=tag:oma-server` — the tag this node claims
- `TAILSCALE_AUTHKEY=` — a pre-auth key; empty means browser login

Five more switches decide what is published — `TAILSCALE_SERVE_FORGEJO`,
`TAILSCALE_SERVE_BRIDGE`, `TAILSCALE_SERVE_HTTPS_PORT` (443),
`TAILSCALE_SERVE_BRIDGE_PORT` (9443), `TAILSCALE_PUBLISH_OPENBOT` — all
`1` by default (§4).

### 3.2 The login

**Browser login** (the default). The installer runs `tailscale up` in the
background, reads the URL it prints and shows it to you:

```
open this on any of your devices:
    https://login.tailscale.com/a1b2c3/a1b2c3
then run:  sudo oma serve refresh
```

**Pre-auth key login** (headless boxes): put the key in `host.env` as
`TAILSCALE_AUTHKEY="tskey-auth-..."`. The key lives 1–90 days and can be
reusable or single-use
([auth keys](https://tailscale.com/docs/features/access-control/auth-keys));
for unattended re-provisioning use an OAuth client secret instead, which
does not expire
([OAuth clients](https://tailscale.com/docs/features/oauth-clients)).

**`tailscale up` flags are not persisted** between runs (client v1.8+). A
later bare `tailscale up` resets them to the defaults and prints a
copy-pasteable full command
([CLI reference](https://tailscale.com/docs/reference/tailscale-cli#up)). The
kit therefore keeps the canonical command on disk at
`/etc/oma-stack/tailscale-up.cmd`; re-apply that file — not a subset of it
— after any `tailscale up`, `tailscale down` or re-authentication.

### 3.3 The tag caveat

The node is tagged `tag:oma-server`, which has three consequences
([tags](https://tailscale.com/docs/features/tags)):

- **A tag and a pre-auth key do not go together.** The auth key carries its
  own tags; the CLI refuses `--advertise-tags` together with `--auth-key`.
  With a key, the key must be created with the tag pre-assigned. With a
  browser login the tag can be claimed on the command line — but only after
  the policy file that owns the tag has been saved (§5).
- **A tagged device has no user identity.** Applying a tag removes the
  device's user-based authentication: a device cannot be both a user and a
  tag. `oma` is therefore not covered by `autogroup:self` and needs an
  explicit grant (§5).
- **A tagged node does not expire its key.** See §6.

---

## 4. What gets published

### 4.1 The endpoints

| URL | Service | How it is published |
|---|---|---|
| `https://oma.<tailnet>.ts.net/` | Forgejo | `tailscale serve`, HTTPS port 443 → `http://127.0.0.1:3000` |
| `https://oma.<tailnet>.ts.net:9443/` | agent bridge | `tailscale serve`, HTTPS port 9443 → `http://127.0.0.1:8765` |
| `http://<100.x.y.z>:3001` | OpenBot | published on the **tailnet address**, plain HTTP, not through serve |
| `ssh://git@oma.<tailnet>.ts.net:2222` | Forgejo's built-in git SSH server | the port Forgejo itself listens on |

Forgejo is published on the tailnet only when `EXPOSE_MODE` is `tailnet`,
which is the default. In `lan` mode it already answers on the LAN under its
own address and the tailnet leaves it alone; in `caddy` mode the domain owns
the name; in `none` mode nothing publishes it at all. OpenBot's publish is
not gated on the mode — the tailnet address is the only way to reach it.

The serve commands the kit runs, in full:

```bash
sudo tailscale serve --bg --https=443 http://127.0.0.1:3000
sudo tailscale serve --bg --https=9443 http://127.0.0.1:8765
```

Three rules govern those lines
([serve reference](https://tailscale.com/docs/reference/tailscale-cli/serve)):

- **`--bg` is mandatory.** Without it the command runs in the foreground and
  never returns, so the `Type=oneshot` systemd unit would block until its
  start timeout killed it. `--bg` is also what makes the share survive a
  reboot and a `tailscale down`/`up`.
- **The syntax changed in tailscale 1.52 (October 2023).** The old
  `tailscale serve 3000 https` forms are gone; the kit falls back to the
  legacy form for port 443 only and warns otherwise, because multi-port
  publishing needs tailscale ≥ 1.52
  ([the change](https://tailscale.com/blog/reintroducing-serve-funnel)).
- **Serve proxies only to `http://127.0.0.1:<port>`.** That is why the
  services keep a loopback bind. A container published to `0.0.0.0` is not
  reachable, and `host.docker.internal` on Linux is the **Docker bridge
  gateway**, not `tailscale0` — never a serve target, and it would put the
  service back on the LAN
  ([Docker guide](https://tailscale.com/blog/docker-tailscale-guide)).

The bridge is the one service that does not keep a loopback bind: it binds
`0.0.0.0:8765` so the OpenBot container can reach it, and it refuses every
caller outside its CIDR allowlist. Serve still targets `127.0.0.1:8765`,
which is inside the allowlist
([ADR-0003](adr/0003-bridge-peer-cidr-allowlist.md)).

Forgejo's git SSH server is separate from its web UI: the kit writes
`SSH_PORT = 2222`, `SSH_LISTEN_PORT = 2222` and `START_SSH_SERVER = true`
into `/etc/forgejo/app.ini`, and the refresh rewrites `SSH_DOMAIN` to the
tailnet name so clone URLs point at the tailnet. No listen host is pinned
for that port — check it with `ss -ltn 'sport = :2222'`; if it is bound to
`0.0.0.0` it is on the LAN too.

### 4.2 OpenBot — the one exception

OpenBot is **not** published through `tailscale serve`. It is published on
the tailnet **address**, in plain HTTP: `http://100.x.y.z:3001`.

The reason is upstream behaviour, not preference. OpenBot in single-user mode
(`OPENBOT_SINGLE_USER=true`, the kit default) admits **every request as one
administrator with no sign-in**. Upstream therefore refuses to start when it
is told about a *public* address in `OPENBOT_PUBLIC_URL`,
`OPENBOT_APP_URL` or `TRUSTED_ORIGINS` — a MagicDNS name such as
`oma.<tailnet>.ts.net` is classified as public, while a `100.64.0.0/10`
CGNAT address is classified as private and only produces a warning. The
classification is in `server/src/config.ts`, function `reachOf()`. So the
tailnet address goes in and the name does not. The transport is already
encrypted: the tailnet path is WireGuard, so plain HTTP inside the tailnet
is not plain HTTP on the wire.

The kit implements this in `components/tailscale/serve-refresh.sh`, in two
steps. First it writes `components/openbot/docker-compose.override.yml`,
publishing the container on the tailnet address as well as loopback:

```yaml
services:
  openbot:
    ports: ["100.x.y.z:3001:3001"]
```

Docker Compose merges this override automatically, because the OpenBot unit
runs `docker compose up -d` with the project directory as its working
directory; delete the file to take OpenBot off the tailnet, and the next
`oma serve refresh` removes it too. Second, the refresh appends the origin
`http://<100.x.y.z>:3001` to `TRUSTED_ORIGINS` in
`/etc/oma-stack/openbot.env` — without it the browser's `Origin` header is
refused and the app does not talk to its own API. So **OpenBot's URL is an
address, not a name**: it changes when the tailnet address changes and is
not covered by the HTTPS certificates Serve issues for the `.ts.net` name.
`oma open` prints the current one.

---

## 5. The access policy

The kit ships a policy template at `components/tailscale/tailnet-policy.json`
and installs it to `/etc/oma-stack/tailnet-policy.json`. The kit does not
apply it for you — there is no CLI for that. Paste it into the admin
console: **Settings → Access controls**.

**Apply it before you log the box in with the tag.** The file creates
`tagOwners` for `tag:oma-server`, and the CLI refuses to apply a tag whose
owner list does not cover you. A node that fails the tag claim comes up
untagged: it keeps a 180-day key and is not covered by the grant.

### What it grants

`tagOwners` gives `tag:oma-server` to `autogroup:admin`. The grants are:

| src | dst | ip | Covers |
|---|---|---|---|
| `autogroup:member` | `autogroup:self` | `*` | the owner's own **user-owned** devices: iPhone, iPad, Mac Studio, `hl-pve01` |
| `autogroup:member` | `tag:oma-server` | `tcp:443` | Forgejo, published through serve |
| `autogroup:member` | `tag:oma-server` | `tcp:9443` | the agent bridge, published through serve |
| `autogroup:member` | `tag:oma-server` | `tcp:2222` | Forgejo's built-in git SSH server |
| `autogroup:member` | `tag:oma-server` | `tcp:22` | the box's own system SSH |

Two things to internalise about this file
([grants](https://tailscale.com/docs/reference/syntax/grants) ·
[policy file](https://tailscale.com/docs/reference/syntax/policy-file)):

- **There is no `acls` key, and that is deliberate.** A tailnet with no
  saved policy uses the **default allow-all** policy, not deny-all
  ([ACLs](https://tailscale.com/docs/features/access-control/acls)). Grants
  are deny-by-default, and Tailscale's own examples are grants-only files
  with no `acls` section
  ([examples](https://tailscale.com/docs/reference/examples/grants)). Do not
  add `"acls": []`: an empty `acls` section means "deny all", which with
  grants is a different and ambiguous configuration.
- **`autogroup:self` never matches a tagged device.** It applies only to
  user-owned devices and cannot be combined with `autogroup:tagged`. That is
  why the tagged server `oma` needs the explicit `tag:oma-server` grant.

### What changes when you save it

Saving a policy file that contains a `grants` section **flips the tailnet
from allow-all to deny-by-default**. From that moment every unlisted path is
denied: any port on `oma` other than 443, 9443, 2222 and 22, and any service
on `oma` that is not in the grants. Save it deliberately, not as a routine.
The console validates the file on save and rejects an invalid one.

---

## 6. Key expiry

Node keys expire. The default period is **180 days**
([key expiry](https://tailscale.com/docs/features/access-control/key-expiry)).

| Node | Key expiry |
|---|---|
| `oma` (`tag:oma-server`) | **disabled** — tagging a device turns node-key expiry off by default ([tags](https://tailscale.com/docs/features/tags#key-expiry)) |
| iPhone, iPad, Mac Studio, `hl-pve01` | 180 days. They are **not** tagged, so they still expire and must be reauthorized from the admin console |

When a key expires and the node does not re-authenticate, connections to and
from that endpoint stop working.

### Checking

```bash
tailscale status --json | jq -r '
  (.Self.KeyExpiry // "never") as $e | "self expires \($e)",
  (.Peer[] | select(.KeyExpiry != null) | "\(.DNSName) expires \(.KeyExpiry)")'
```

The three fields that matter are `.Self.KeyExpiry`, `.Self.Expired` and
`.Peer[*].KeyExpiry`. Alert when any of them is inside **30 days**, or when
`.Self.Expired` / `.Peer[*].Expired` is already `true`.

### Fixing

**Preferred, no interruption.** In the admin console → *Settings → Key
expiry*: **"Temporarily extend key"** (+30 minutes) to get back in, then
**"Reauthorize machine"** on the device to mint a fresh 180-day key.

**Unattended, for a box.** Re-authenticate with a fresh auth key or an OAuth
client secret — the secret does not expire
([OAuth clients](https://tailscale.com/docs/features/oauth-clients)):

```bash
sudo tailscale up --auth-key="$(cat /root/.config/tailscale/authkey)" \
  --hostname=oma --accept-dns=1 --ssh=0 --advertise-tags=tag:oma-server
```

**From the device itself.** `tailscale logout` then `tailscale up` (browser
flow), or `tailscale up --force-reauth`
([logout](https://tailscale.com/docs/reference/tailscale-cli#logout)). A
logout on an ephemeral node removes the node from the tailnet immediately.
Revoking an auth key does **not** deauthorize the nodes that already used it.

---

## 7. Day-2 operations

### The commands

```bash
sudo oma serve show      # tailscale serve status
sudo oma serve refresh   # re-publish everything (also runs at every boot)
sudo oma doctor          # the whole box, tailnet section included
sudo oma open            # the URLs, tailnet ones included
```

`oma serve refresh` is idempotent: it re-reads the tailnet name and address
from `tailscale status --json`, rewrites Forgejo's `ROOT_URL`, `DOMAIN` and
`SSH_DOMAIN`, rewrites the OpenBot override and its `TRUSTED_ORIGINS`, then
re-applies both serve entries. Run it after a tailnet rename, a change of
address, or any manual edit of the serve configuration.

### Health fields

`oma doctor` prints the tailnet section from `tailscale status --json`:
backend state, name, addresses, tags, expiry and health problems. The raw
fields behind it
([ipnstate structs](https://github.com/tailscale/tailscale/blob/main/ipn/ipnstate/ipnstate.go)):

| Field | Healthy | When it is wrong |
|---|---|---|
| `BackendState` | `Running` | `NeedsLogin` → logged out: `sudo tailscale up`. `Stopped` → the daemon is down: `systemctl status tailscaled` |
| `Health` | empty | any entry names a real problem — read it literally |
| `Self.DNSName` | `oma.<tailnet>.ts.net.` | empty → MagicDNS off, or HTTPS never enabled; no name means nothing to publish |
| `Self.TailscaleIPs` | a `100.64.0.0/10` and an `fd7a:…` address | empty → not logged in |
| `Self.Online` | `true` | `false` → the node is not reachable from the control plane |
| `Self.Expired` | `false` | `true` → the node key expired: re-authenticate (§6) |
| `Self.KeyExpiry` | absent, or far off | inside 30 days → re-authorize (§6); 180 days out on a tagged node means the tag was not applied |
| `Self.Tags` | `["tag:oma-server"]` | empty → the tag claim failed; save the policy first (§5), then re-run `tailscale up` |
| `CurrentTailnet.MagicDNSSuffix` | `example-tailnet.ts.net` | empty → MagicDNS is disabled tailnet-wide |
| `CertDomains` | contains `oma.<tailnet>.ts.net` | missing it → Serve has no certificate; enable HTTPS in the admin console |

### DNS

The kit defaults to `--accept-dns=1`, so tailscale answers DNS for the whole
tailnet and `oma.<tailnet>.ts.net` resolves system-wide. With `0` the OS
resolver is left alone and that name may not resolve on the box — the
internal Tailscale resolver still holds the MagicDNS records, but the OS
does not use it. Compare the two paths:

```bash
tailscale dns query oma.<tailnet>.ts.net     # through the local forwarder
resolvectl query oma.<tailnet>.ts.net        # through the OS resolver
```

If the first works and the second does not, turn DNS acceptance back on
(`TAILSCALE_ACCEPT_DNS="1"`, then re-apply
`/etc/oma-stack/tailscale-up.cmd`) or add an explicit `~<tailnet>.ts.net`
route to `100.100.100.100` in systemd-resolved
([DNS reference](https://tailscale.com/docs/reference/tailscale-cli#dns)).

Other diagnostics: `sudo tailscale serve status --json` for the active serve
configuration, `sudo tailscale netcheck` for connectivity and DERP
diagnostics, `sudo tailscale bugreport` to attach to a bug report.

---

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| The phone cannot open `https://oma.<tailnet>.ts.net/` | The phone is not signed in to the same tailnet, or the policy denies the port | Check the phone's Tailscale app: same account, same tailnet. Then check the policy: `tcp:443` must be granted to `tag:oma-server` |
| The phone cannot open the tailnet URL, but `oma` can | The phone is on a network that blocks the tailnet, or its exit node is down | Toggle the phone's Tailscale off and on; try it on mobile data |
| The phone cannot open Forgejo but OpenBot works | OpenBot is published on the tailnet address; Forgejo needs the serve certificate | Check `CertDomains` contains `oma.<tailnet>.ts.net` and that HTTPS is enabled in the admin console |
| `tailscale serve` hangs | `--bg` is missing: the command runs in the foreground | Use `sudo tailscale serve --bg --https=443 http://127.0.0.1:3000` |
| `oma serve refresh` says "your tailscale is too old" | tailscale < 1.52; the modern serve syntax does not exist | `sudo pacman -Syu tailscale` |
| A serve entry points at a port that answers nothing | The target is not on loopback, or the port was published to `0.0.0.0` | Serve proxies only to `http://127.0.0.1:<port>`. Publish the container to `127.0.0.1:<port>:<port>` |
| OpenBot refuses to start after a tailnet name was added to `TRUSTED_ORIGINS` | Single-user mode refuses to start when it is given a public address, and a `.ts.net` name is public to it | Use the `100.x` tailnet address instead of the MagicDNS name. The kit does this for you (§4.2) |
| OpenBot's page loads but the app does not talk to its own API | The origin is not trusted | `http://<100.x.y.z>:3001` must be in `TRUSTED_ORIGINS` in `/etc/oma-stack/openbot.env` |
| The box is on the tailnet but nothing is published | The serve unit has not run since login | `sudo oma serve refresh` |
| Forgejo's links point at `127.0.0.1` | `ROOT_URL` was not rewritten to the tailnet name | `sudo oma serve refresh` — it rewrites `ROOT_URL`, `DOMAIN` and `SSH_DOMAIN` and restarts Forgejo |
| `oma doctor` shows the tags as `(none)` | The tag claim failed because the policy was not saved first | Save `/etc/oma-stack/tailnet-policy.json` in the admin console, then re-run `tailscale up` |
| `oma doctor` shows a 180-day expiry on a tagged node | The node is not tagged | Same as above: save the policy, then re-apply `/etc/oma-stack/tailscale-up.cmd` |
| A device stopped working after about six months | Its node key expired | Reauthorize it from the admin console, or re-run `tailscale up --force-reauth` (§6) |
| The tailnet name resolves in the tailscale resolver but not in the system | `--accept-dns=0`, or the OS resolver points elsewhere | `tailscale dns query <name>` vs `resolvectl query <name>` (§7) |
| A service is reachable over the LAN | It is bound to `0.0.0.0` | The tailnet grant does not restrict a bind address. Check `ss -ltnp` and put the service back on `127.0.0.1` |
| Tailnet traffic is dropped while Docker runs | Tailscale's netfilter rules and Docker's iptables rules fight | `--netfilter-mode=nodivert` or `off` ([netfilter modes](https://tailscale.com/docs/reference/netfilter-modes)) |
