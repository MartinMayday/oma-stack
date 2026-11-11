# DEPLOY — putting oma-stack on "oma"

The target is a 2014 Intel MacBook Pro running Omarchy (Arch), 8 GB RAM,
128 GB internal SSD, 512 GB SD card, 4 TB USB SATA.

---

## 0. Before you start

| Check | Command | Wanted |
|---|---|---|
| Architecture | `uname -m` | `x86_64` |
| Distro | `cat /etc/os-release \| grep PRETTY` | Arch / Omarchy |
| Root | `sudo -v` | works without a password prompt later |
| Disk space | `df -h /` | 10 GB free on the internal SSD |
| USB disk (optional) | `lsblk -f` | a 4 TB disk, not required |
| SD card (optional) | `lsblk -f` | a 512 GB card, not required |

Nothing external is needed to start. The USB disk and the SD card are
optional: the stack works without either, and the healthcheck says so.

---

## 1. Install

**One line:**

```bash
curl -fsSL https://raw.githubusercontent.com/MartinMayday/oma-stack/main/bootstrap.sh | sudo bash
```

**Or clone and run:**

```bash
git clone https://github.com/MartinMayday/oma-stack.git
cd oma-stack
sudo ./bootstrap.sh
```

The installer lands in `/opt/oma-stack` and writes the one config file to
`/etc/oma-stack/host.env`.

### What it does, in order

1. **preflight** — hardware, disks, ports. Changes nothing.
2. **Forgejo** — the server, its SQLite database, the admin user, the API
   token. Starts and waits for `/api/v1/version`.
3. **forgejo-runner** — the CI executor, registered with the local Forgejo,
   as a systemd service.
4. **GitHub runner** — this MacBook as a self-hosted runner for every repo
   the account owns. This is what keeps public-repo CI alive while the
   account is billing-locked.
5. **exposure** — LAN only by default. `EXPOSE_MODE` can switch it to
   Tailscale or Caddy.
6. **always-on** — the lid switch is ignored, suspend is blocked, Docker is
   capped so the desktop keeps its memory.
7. **timers** — mirror, issue snapshot, healthcheck.
8. **backup** — dated snapshots to the USB disk, every 6 hours, 7 kept.
9. **mirrors** — the GitHub repos are cloned into Forgejo.
10. **OpenBot** — the container, its secrets, its systemd unit.
11. **agent bridge** — the registry, the handoff queue, its systemd unit.
12. **tooling** — the small CLI helpers the agents expect.
13. **healthcheck** — one report for the whole stack.

---

## 2. Read the output

Two things are printed once and cannot be recovered:

- the **Forgejo admin password** (user `ci-admin`)
- the **paths of everything that was written**

If you missed the password, reset it:

```bash
sudo -u forgejo forgejo --config /etc/forgejo/app.ini \
  admin user change-password --username ci-admin --password 'new-password'
```

---

## 3. The two values only you have

```bash
sudo nano /etc/oma-stack/openbot.env
```

| Key | Where it comes from |
|---|---|
| `CPK_INTELLIGENCE_API_KEY` | `npx --yes copilotkit@latest login` → `npx --yes copilotkit@latest project select` |
| `OPENAI_API_KEY` | your model provider (or `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`) |

Without the first, OpenBot does not start. Without the second, the Bots have
no model to spend.

Then:

```bash
sudo systemctl restart oma-openbot.service
```

For local Intelligence instead of the hosted one:

```bash
cd /opt/oma-stack && npx --yes copilotkit@latest local connect
```

---

## 4. Let the mirror reach private repositories

```bash
sudo install -d -m 0700 /etc/oma-stack
sudo tee /etc/oma-stack/github.token >/dev/null <<< 'ghp_your_token_here'
sudo chmod 0600 /etc/oma-stack/github.token
sudo /opt/oma-stack/stack/mirror/mirror-sync.sh
```

---

## 5. Register an agent in OpenBot

Open the UI at <http://127.0.0.1:3001>, go to `/bots`, and add an AG-UI
agent:

```
http://host.docker.internal:8765/ag-ui/echo
```

`echo` is the built-in example agent — it echoes the prompt back, which
proves the whole path works. Replace it with a real agent once the registry
is filled in. See [AGENT-BRIDGE.md](AGENT-BRIDGE.md).

---

## 6. Check it

```bash
sudo /opt/oma-stack/verify/healthcheck.sh
```

Wanted:

```
PASS  forgejo.service: active
PASS  forgejo.http: 200 on http://127.0.0.1:3000
PASS  storage.internal: internal SSD 12% used
PASS  forgejo-runner: active
PASS  github-runner: service running
PASS  mirror.freshness: last sync 2 min ago
PASS  openbot.http: answering on 3001
PASS  agent-bridge.http: answering on 8765
```

A **WARN** about the USB disk is expected when the disk is not plugged in.

---

## 7. Expose it (optional)

```bash
sudo nano /etc/oma-stack/host.env      # EXPOSE_MODE=tailscale
sudo /opt/oma-stack/stack/install/40-exposure.sh
```

Tailscale needs the `tailscale` package and a tailnet. Caddy needs a domain
and ports 80/443 open.

OpenBot and the bridge are **not** exposed by that script: OpenBot's port is
published on loopback on purpose, and the bridge is an internal seam.

---

## 8. Start it again after a reboot

Nothing to do: every unit is enabled. The order is handled by systemd —
Forgejo before the runner, Docker before OpenBot.

```bash
systemctl list-timers 'oma-*'       # the timers
systemctl list-units 'forgejo*' 'oma-*'   # the services
```

---

## 9. Roll back

```bash
sudo /opt/oma-stack/uninstall.sh           # stop the services, keep the data
sudo /opt/oma-stack/uninstall.sh --purge   # and delete the data
```

GitHub is never touched.
