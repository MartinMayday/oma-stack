# oma-stack

One command puts a working CI box, an agent surface and an agent bridge on
an Omarchy MacBook Pro.

Built for a 2014 Intel MacBook Pro (dual-core i5, 8 GB RAM, 128 GB internal
SSD, 512 GB SD card, 4 TB USB SATA) running Arch/Omarchy, after the
`MartinMayday` GitHub account was found to be **billing-locked**: GitHub
refuses to start any hosted job, and private-repo workflows do not even
register.

| Piece | What it is | Where it runs |
|---|---|---|
| **Forgejo** | the tracker + the mirror + the CI server | on the MacBook |
| **forgejo-runner** | the CI executor | on the MacBook, host label |
| **GitHub runner** | self-hosted, keeps public-repo CI alive | on the MacBook |
| **OpenBot** | the agent surface (CopilotKit/OpenBot) | one Docker container |
| **agent bridge** | local agents over AG-UI + the handoff queue | one systemd service |

GitHub stays canonical for git, issues and PRs. Forgejo is the CI executor
and the offline mirror. OpenBot is where an agent talks to a human.

---

## Install

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

Both land in `/opt/oma-stack` and write one config file to
`/etc/oma-stack/host.env`. **That is the only file you edit.** Re-running is
safe: every step checks whether it already did its job, and every secret that
exists is kept.

Useful flags:

```bash
sudo ./bootstrap.sh -- --no-openbot     # Forgejo and CI only
sudo ./bootstrap.sh -- --no-bridge      # no agent bridge
sudo ./bootstrap.sh -- --no-runner      # server only, no runners
```

---

## Two things only you can supply

Everything else is generated. These two are not:

```bash
sudo nano /etc/oma-stack/openbot.env
```

| Value | Where it comes from |
|---|---|
| `CPK_INTELLIGENCE_API_KEY` | `npx --yes copilotkit@latest login` then `npx --yes copilotkit@latest project select` — or `npx --yes copilotkit@latest local connect` for local Intelligence |
| `OPENAI_API_KEY` (or `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`) | your model provider |

Then:

```bash
sudo systemctl restart oma-openbot.service
```

The Forgejo admin password is printed once by the installer. Write it down.

---

## What you get

```
Forgejo        http://localhost:3000        the tracker, the mirror, CI
OpenBot        http://127.0.0.1:3001        the agent surface
agent bridge   http://127.0.0.1:8765        AG-UI endpoints for your agents
```

Systemd services and timers:

| Unit | What it does | When |
|---|---|---|
| `forgejo.service` | the tracker and CI server | always on |
| `forgejo-runner.service` | executes the workflows | always on |
| `oma-openbot.service` | the OpenBot container | always on |
| `oma-agent-bridge.service` | the bridge | always on |
| `oma-mirror-sync.timer` | GitHub → Forgejo | every 15 min |
| `oma-issue-snapshot.timer` | read-only issue snapshot | every 30 min |
| `oma-healthcheck.timer` | the whole stack | every 10 min |
| `oma-backup.timer` | snapshot to the USB disk | every 6 h |

---

## Daily use

```bash
sudo /opt/oma-stack/verify/healthcheck.sh     # is it healthy
systemctl list-timers 'oma-*'                 # what is scheduled
journalctl -u oma-agent-bridge -f             # watch the bridge
sudo /opt/oma-stack/stack/mirror/mirror-sync.sh   # force a mirror now
```

---

## Storage rules

| Disk | Holds | Never holds |
|---|---|---|
| 128 GB internal SSD | Forgejo DB, **repositories**, Actions logs + artifacts, mirror cache, Docker data-root, OpenBot database | — |
| 4 TB USB SATA | dated backup snapshots only | **anything Forgejo needs to run** |
| 512 GB SD card | optional runner scratch | **the database, the repos, ever** |

The USB disk is *not* a dependency. Unplug it and CI, the mirror and the
tracker keep running — only the backups skip themselves, and the healthcheck
says **WARN**, not FAIL.

---

## The agent bridge

OpenBot can only call an AG-UI agent whose host is on an exact-match
allowlist. The bridge is what puts your local agents on that list.

```
OpenBot ──AG-UI/SSE──► bridge ──stdin──► qoder / glm / minimax
                            │
                            └── watches the handoff inbox, writes answers
                                to the outbox, logs to audit.log
```

The bridge never merges, deploys, or touches a credential. A case with an
assignee is run; its answer is written to the outbox for a human to approve.

Register one agent in OpenBot:

```
http://host.docker.internal:8765/ag-ui/qoder
```

The registry is `/etc/oma-stack/agents.json`. See
[docs/AGENT-BRIDGE.md](docs/AGENT-BRIDGE.md).

---

## Layout

```
oma-stack/
├── bootstrap.sh              the curl entry point
├── install.sh                the orchestrator
├── uninstall.sh              take it back off
├── config/host.env           the one file you edit
├── stack/                    Forgejo + CI + mirror + backup (the tested layer)
├── components/
│   ├── openbot/              the OpenBot container
│   ├── agents/               the bridge and the agent registry
│   └── tooling/              the CLI helpers the agents expect
├── verify/healthcheck.sh     one healthcheck for the whole stack
├── docs/                     DEPLOY, RUNBOOK, AGENT-BRIDGE
└── tests/                    the harness and the unit tests
```

---

## Tests

```bash
bash tests/harness.sh                      # the functional harness
python3 -m unittest discover -s tests      # the bridge unit tests
```

The harness runs against local fakes — real bind mounts, real bare git
repos, a real sqlite database. No root, no docker, no network.

---

## Uninstall

```bash
sudo /opt/oma-stack/uninstall.sh           # stop the services, keep the data
sudo /opt/oma-stack/uninstall.sh --purge   # and delete the data
```

GitHub is never touched. The mirror only ever reads from it.
