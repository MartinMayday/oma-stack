# oma-stack

**Your own AI workshop. On hardware you own.**

One Omarchy MacBook Pro becomes a git forge, a CI executor, an agent surface
and a bridge to the agent CLIs already installed on it. GitHub stays canonical
for git, issues and pull requests. Your machine does the work.

Built for a 2014 Intel MacBook Pro — dual-core i5, 8 GB RAM, 128 GB internal
SSD, 512 GB SD card, 4 TB USB SATA — after the `MartinMayday` GitHub account
turned out to be **billing-locked**: GitHub refuses to start any hosted job,
and private-repository workflows never even register.

---

## What this is

Five pieces, one machine, one operator.

- **Forgejo** — the tracker, the mirror and the CI server. Repositories come
  across from GitHub every fifteen minutes, one way. Issues are snapshotted
  every thirty, read-only.
- **forgejo-runner** — the CI executor. It takes your pipeline runs and keeps
  the logs and the artifacts on a disk you own.
- **GitHub self-hosted runner** — this MacBook, registered with GitHub, so
  public repositories keep their CI alive while the account is locked.
- **OpenBot** — the agent surface. One container carries the app, the API, the
  browser the Bots drive and the database.
- **The agent bridge** — the seam between OpenBot and your local agent CLIs.
  It speaks AG-UI over SSE, runs the handoff queue, and writes every answer to
  the outbox for a human to read.

One command drives all of it. `oma doctor` tells you what is broken and what
to do about it.

---

## What this is not

- **Not a replacement for GitHub.** Git, issues and pull requests live on
  GitHub. Forgejo is the CI executor and the offline mirror; the mirror reads
  and never writes back.
- **Not a cluster.** One machine, one runner, one operator. It runs one
  person's pipelines, not a team's.
- **Not a fix for the billing lock.** GitHub refusing to start hosted jobs is
  upstream's problem. This kit moves the execution to your own hardware. It
  does not unlock the account, and it cannot.
- **Not keyless.** OpenBot needs a CopilotKit Intelligence key — without it
  the server refuses to start. A model provider key is optional: it is only
  needed by OpenBot's own Bots, not to boot. Every other secret the installer
  generates for you.
- **Not a fleet of agents.** The agents are the CLI programs already on this
  box — `qoder`, `claude`, `codex`. The kit wires them to OpenBot and records
  what they answered. It brings no intelligence of its own.

---

## Install

One line:

```bash
curl -fsSL https://raw.githubusercontent.com/MartinMayday/oma-stack/main/bootstrap.sh | sudo bash
```

Or clone it and run it yourself:

```bash
git clone https://github.com/MartinMayday/oma-stack.git
cd oma-stack
sudo ./bootstrap.sh
```

Both land in `/opt/oma-stack` and write one file you edit:
`/etc/oma-stack/host.env`. Re-running is safe — every step checks whether it
already did its job, and every secret that exists is kept.

| Requirement | Why |
|---|---|
| Arch or Omarchy, x86_64 | The installer is `pacman` and `systemd` based. |
| root | It installs services, not processes. |
| 10 GB free on the internal SSD | Forgejo, the runners, Docker and the OpenBot image. `docs/DEPLOY.md` has the full breakdown. |
| a CopilotKit Intelligence key | OpenBot will not start without it. |
| a model provider key | Optional. Only OpenBot's own Bots spend it. |

The keys go in one file, mode 0600:

```bash
sudo nano /etc/oma-stack/openbot.env
```

| Value | Where it comes from | Needed to boot |
|---|---|---|
| `CPK_INTELLIGENCE_API_KEY` | `npx --yes copilotkit@latest login`, then `npx --yes copilotkit@latest project select` | yes |
| `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` or `GOOGLE_API_KEY` | your model provider | no — only for OpenBot's own Bots |

Then:

```bash
sudo systemctl restart oma-openbot.service
oma doctor
```

The Forgejo admin password is printed once by the installer. Write it down.

---

## Your devices

Every service keeps its own bind: Forgejo on `127.0.0.1`, OpenBot on
`127.0.0.1`, the agent bridge on the host address with a CIDR allowlist in
front of it. `tailscale serve` publishes Forgejo and the bridge over HTTPS,
and to nowhere else: no router port forwards, no public certificate, no
funnel. The tailnet is optional — without it everything still runs on
localhost.

One thing worth knowing: Forgejo's own reachability is set by `EXPOSE_MODE`
in `/etc/oma-stack/host.env`. The default, `tailnet`, keeps it on loopback
and lets the tailnet publish it. `none` keeps it on this box alone. `lan`
puts it on your LAN and is the only mode that does. `caddy` is the only mode
that puts it on the public internet, and it is off.

| Device | What it is for | On the tailnet |
|---|---|---|
| iPhone | OpenBot in the browser, Forgejo on the go | Tailscale app |
| iPad | Review a diff, file a case, approve a run | Tailscale app |
| MacBook Pro (`oma`) | The workshop itself: CI, agents, data | the host |
| Mac Studio (M1 Max) | Heavy builds and model runs | Tailscale app, headless |
| Proxmox node (`hl-pve01`) | VMs and containers | Tailscale in the host or in a container |

`components/tailscale/tailnet-policy.json` is the access policy to paste into
the Tailscale console. Saving it turns the tailnet from allow-all into
deny-by-default: after that, only the ports it lists are reachable.

See [docs/TAILNET.md](docs/TAILNET.md).

---

## The day-to-day

`oma` is the whole interface. It reads. It never merges, deploys, or touches
a credential.

| Command | What it is for |
|---|---|
| `oma status` | One screen: services, timers, endpoints. |
| `oma doctor` | What is broken, and what to do about it. |
| `oma open` | The URLs, copy-pasteable. |
| `oma logs <unit>` | Follow a log. |
| `oma agent list` | The agents the bridge can run. |
| `oma agent test <name>` | Run one prompt through one agent. |
| `oma handoff ls` | The queue: inbox, outbox, done, failed. |
| `oma handoff put <file>` | File a case for an agent. |
| `oma handoff watch` | Follow the answers. |
| `oma serve show` | The tailnet entry points. |
| `oma serve refresh` | Publish them again. |
| `oma update` | Pull the newest kit and reinstall. |
| `oma uninstall` | Take it off. |
| `oma version` | The version string. |
| `oma help` | The same list. |

---

## How it is put together

| Component | What | Where it runs |
|---|---|---|
| Forgejo | the tracker, the mirror, the CI server | `forgejo.service` on the MacBook |
| forgejo-runner | executes your pipelines | `forgejo-runner.service` on the MacBook |
| GitHub runner | keeps public-repo CI alive | `actions.runner.*` on the MacBook |
| OpenBot | the agent surface | one Docker container, `oma-openbot.service` |
| Agent bridge | AG-UI and the handoff queue | one systemd service, `oma-agent-bridge.service` |
| Tailscale | how the other four devices reach it | `tailscaled`, `oma-tailscale-serve.service` |

Storage is tiered, and the tiers are not negotiable:

| Disk | Holds | Never holds |
|---|---|---|
| 128 GB internal SSD | Forgejo database, repositories, Actions logs and artifacts, mirror cache, Docker data-root, OpenBot database | — |
| 4 TB USB SATA | dated backup snapshots | anything Forgejo needs to run |
| 512 GB SD card | optional runner scratch | the database, the repositories |

The USB disk is not a dependency. Unplug it and the tracker, the mirror and CI
keep running: the backup timer skips itself and the healthcheck reports WARN,
not FAIL.

---

## Documentation

| Document | What it covers |
|---|---|
| [docs/DEPLOY.md](docs/DEPLOY.md) | Installing it on "oma", and what the installer does, in order. |
| [docs/AGENT-BRIDGE.md](docs/AGENT-BRIDGE.md) | The agent registry, the AG-UI endpoints, the handoff queue. |
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | Day two: what to do when something is broken. |
| [docs/TAILNET.md](docs/TAILNET.md) | The five devices, the access policy, publishing the stack. |
| [docs/adr/](docs/adr/) | The six architecture decisions, with the constraint behind each one and the alternatives that lost. |
| [SECURITY.md](SECURITY.md) | The posture, what is in scope, how to report a problem. |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Tests, style, the approval rules. |
| [LICENSE](LICENSE) | MIT. |

---

## License

MIT. Copyright (c) 2026 MartinMayday.
