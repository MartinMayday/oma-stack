# RUNBOOK — day 2 operations for the whole box

One command tells you whether the box is healthy:

```bash
oma doctor
```

It runs the healthcheck and adds the parts a script cannot judge: the
secrets, the agents, the tailnet. Everything else in this document is what
you do when it is not.

| Symptom | Go to |
|---|---|
| Forgejo won't load | §1 |
| A CI job hangs or never starts | §2 |
| The mirror is stale | §3 |
| OpenBot won't start | §4 |
| An agent doesn't answer / no handoff result | §5 |
| The USB disk is missing | §6 |
| The box won't stay awake | §7 |
| A device cannot reach the box | §8 |
| Something needs to be undone | §9 |

---

## 0. The map

| Thing | Where |
|---|---|
| Config you edit | `/etc/oma-stack/host.env` |
| Secrets | `/etc/oma-stack/*.token`, `/etc/oma-stack/openbot.env` (mode 0600) |
| Agent registry | `/etc/oma-stack/agents.json` |
| Installed code | `/opt/oma-stack/` |
| Forgejo data (DB + repos) | `/var/lib/forgejo/` |
| OpenBot data | `/var/lib/forgejo/openbot/` + docker volumes `oma-openbot-data`, `oma-openbot-workspace`, `oma-openbot-profiles` |
| Handoff queue | `/var/lib/oma-stack/handoff/{inbox,outbox,done,failed}` |
| Tailnet policy template | `/etc/oma-stack/tailnet-policy.json` |
| The canonical `tailscale up` | `/etc/oma-stack/tailscale-up.cmd` |
| Health log | `/var/log/oma-stack-health.log` |
| Backups | `/mnt/usb/backups/` |

Log in to Forgejo as `ci-admin`. The password was printed **once**, during
install. If you lost it, reset it:

```bash
sudo forgejo --config /etc/forgejo/app.ini admin user change-password \
  --username ci-admin --password '<new-password>'
```

---

## 1. Forgejo is down

```bash
systemctl status forgejo
journalctl -u forgejo -n 50 --no-pager
sudo /opt/oma-stack/verify/healthcheck.sh
```

Most common causes, in order:

| Cause | Fix |
|---|---|
| The internal SSD is not mounted (the data lives there) | `mount` / check `lsblk` — see §6 |
| Config points at a USB disk | `grep BOOT_DATA /etc/oma-stack/host.env` — it must be the internal SSD |
| Port 3000 taken | `ss -ltnp \| grep 3000` |
| Corrupt SQLite DB | `sudo systemctl stop forgejo` → restore the newest snapshot from §6 → start |

Never delete `/var/lib/forgejo`. That is the tracker, the repositories and the
CI history in one directory.

---

## 2. A CI job hangs or never starts

### 2a. On GitHub

GitHub-hosted jobs **will not start** — the account is billing-locked. This is
not a bug you can fix in a workflow file. See
[stack/docs/RUNBOOK.md](../stack/docs/RUNBOOK.md) for the full triage, and
[stack/docs/GITHUB-BILLING-CHECKLIST.md](../stack/docs/GITHUB-BILLING-CHECKLIST.md)
for the (currently unfixable) billing path.

Public repos still work **if** the self-hosted runner is online:

```bash
systemctl status actions.runner.*
systemctl list-timers 'oma-*'
```

### 2b. On Forgejo

```bash
journalctl -u forgejo-runner -n 80 --no-pager
sudo ls /var/lib/forgejo/actions-log/        # the run logs
```

| Symptom | Cause | Fix |
|---|---|---|
| No run appears at all | The workflow file is not where Forgejo looks | Put it in `.forgejo/workflows/` (then `.gitea/workflows/`, then `.github/workflows/`) |
| Run appears, stuck "waiting for runner" | Labels do not match | `runs-on:` must be a subset of `self-hosted linux x64` |
| Run appears, fails instantly | The action needs Node | `uses:` an action that is not vendored — pin to a `docker://` or a local script |
| Runner offline after a reboot | The service is not enabled | `sudo systemctl enable --now forgejo-runner` |

See [stack/docs/WORKFLOWS.md](../stack/docs/WORKFLOWS.md) for the workflow
format that runs on this box.

---

## 3. The mirror is stale

The mirror copies GitHub → Forgejo. It never writes to GitHub.

```bash
systemctl status oma-mirror-sync.timer
sudo /opt/oma-stack/stack/mirror/mirror-sync.sh     # force it now
journalctl -u oma-mirror-sync -n 50 --no-pager
```

| Symptom | Cause | Fix |
|---|---|---|
| `401`/`403` from GitHub | The PAT is missing, expired or lacks `repo` | Rewrite `/etc/oma-stack/github.token` (mode 0600), then re-run |
| `repository not found` | The name in `MIRROR_REPOS` is wrong | `gh repo list MartinMayday` to get the exact names |
| Nothing mirrors | `GITHUB_TOKEN_FILE` points elsewhere | Check `host.env` §8 |
| Runs but pushes nothing | The local repo is dirty | `sudo git -C /var/lib/forgejo/mirror-cache/<repo> status` |

---

## 4. OpenBot won't start

```bash
sudo systemctl status oma-openbot
sudo docker compose -f /opt/oma-stack/components/openbot/docker-compose.yml ps
sudo docker compose -f /opt/oma-stack/components/openbot/docker-compose.yml logs --tail=80 openbot
```

The container needs **three** things to start, and a fourth for OpenBot's
own Bots. The healthcheck names the missing one.

| Missing | Symptom in the log | Fix |
|---|---|---|
| `CPK_INTELLIGENCE_API_KEY` | refuses to start | `npx --yes copilotkit@latest login` then `project select`, or `local connect` |
| `KEY_ENCRYPTION_KEY` | refuses to start | `openssl rand -base64 32` into `/etc/oma-stack/openbot.env` |
| `INTELLIGENCE_API_URL` / `INTELLIGENCE_GATEWAY_WS_URL` | connects then drops | Copy both values from the same `copilotkit` login |
| a model key (`OPENAI_API_KEY` etc.) | starts, the Bot cannot answer | Only OpenBot's own Bots need it, and the all-in-one image ships none. The agents registered from the bridge answer anyway |

After editing `/etc/oma-stack/openbot.env`:

```bash
sudo systemctl restart oma-openbot.service
curl -fsS http://127.0.0.1:3001/health
```

The browser reaches the Bots at `http://127.0.0.1:3001`, and over the
tailnet at `http://<100.x.y.z>:3001`.

**`OPENBOT_SINGLE_USER=true` means anyone who can reach the port is an
administrator.** Keep the bind on `127.0.0.1` unless you have understood the
consequences.

Four more refusals, all of them upstream's own boot checks:

| The log says | Cause | Fix |
|---|---|---|
| `AGENT_ENDPOINT_ALLOWED_HOSTS entry "…" must be a host…` | A URL, a path or a `*` is in the allowlist | Use `host` or `host:port` only — `host.docker.internal:8765` |
| `OPENBOT_SINGLE_USER … cannot be combined with an address the public internet reaches` | A `.ts.net` name is in `TRUSTED_ORIGINS`, `OPENBOT_APP_URL` or `OPENBOT_PUBLIC_URL` | Use the tailnet **address** (`http://100.x.y.z:3001`), not the name. See [TAILNET.md](TAILNET.md) |
| `AGENT_COMPUTER_POLICY must be valid JSON` | The policy was edited into something the server cannot parse | Restore the line from `components/openbot/install-openbot.sh` |
| `AGENT_STALL_TIMEOUT_MS must be a whole number…` | The value is not a number of milliseconds | Whole milliseconds, or `0` to switch the watchdog off |

---

## 5. An agent doesn't answer, or a handoff never lands

```bash
systemctl status oma-agent-bridge
curl -fsS http://127.0.0.1:8765/health
curl -fsS http://127.0.0.1:8765/agents
journalctl -u oma-agent-bridge -n 80 --no-pager
```

| Symptom | Cause | Fix |
|---|---|---|
| `/agents` shows an agent with no command | The binary is not on the PATH, or the entry is a placeholder | Install the CLI, or fill in `command` in `/etc/oma-stack/agents.json`, then `sudo systemctl restart oma-agent-bridge` |
| The endpoint returns `RUN_ERROR` | Every agent in the chain failed | The message names each one: `qoder: … ; glm: …` |
| The answer came from an agent you did not ask for | The chain fell through | The reply carries `"agent": "<who answered>"`; the audit log names the fallback |
| `403 {"error":"forbidden"}` | The caller is not on the IP allowlist | Add its address to `AGENT_BRIDGE_ALLOWED_IPS` in `host.env`, or use `127.0.0.1` |
| OpenBot says "host not allowed" | The allowlist is exact-match | Add the host to `AGENT_ENDPOINT_ALLOWED_HOSTS` in `/etc/oma-stack/openbot.env`, restart OpenBot |
| A case sits in `inbox/` and never moves | The bridge user cannot read the inbox | `sudo chown -R <bridge-user> /var/lib/oma-stack/handoff` |
| The case is in `failed/` | The agent exited non-zero | Read `<case>.result.md` next to it and `audit.log` |

The queue:

```
/var/lib/oma-stack/handoff/
├── inbox/    drop a case here       (the bridge picks it up)
├── outbox/   the agent's answer
├── done/     finished cases
└── failed/   cases that blew up
```

The bridge **never** merges, deploys or changes a credential. Its output is a
proposal for a human to approve. See
[AGENT-BRIDGE.md](AGENT-BRIDGE.md).

---

## 6. The USB disk is missing

Not fatal. The USB disk holds **backups only**.

```bash
lsblk -f /dev/sdX          # find the right device
sudo mkdir -p /mnt/usb
sudo mount /dev/sdX1 /mnt/usb
```

The healthcheck then reports **WARN** (backups skipped), never **FAIL**. Forgejo,
the mirror and CI keep running on the internal SSD.

Restore a backup after data loss:

```bash
sudo systemctl stop forgejo
sudo tar -xzf /mnt/usb/backups/<timestamp>/forgejo.tar.gz -C /var/lib/forgejo
sudo systemctl start forgejo
```

---

## 7. The box will not stay awake

The lid and idle-suspend are ignored when `ENABLE_ALWAYS_ON=1`:

```bash
systemctl status ci-sleep-inhibitor.service
cat /etc/systemd/logind.conf.d/00-oma-stack.conf
```

If the machine still sleeps:

```bash
sudo systemctl enable --now ci-sleep-inhibitor.service
sudo omarchy toggle suspend
sudo systemctl mask sleep.target suspend.target hibernate.target
```

Omarchy has its own sleep switch, so toggle it too — the systemd mask alone
does not always win.

On battery, expect the CPU to drop below 1 GHz. Set the performance governor
to `performance` for CI bursts, and back to `powersave` afterwards.

---

## 8. A device cannot reach the box

```bash
oma serve show          # what is published
oma serve refresh       # publish it again
tailscale status        # is the node logged in
```

| Symptom | Cause | Fix |
|---|---|---|
| The phone cannot open Forgejo | The phone is not on the tailnet | Install the Tailscale app and sign in with the same account |
| The phone is on the tailnet and still refused | The access policy denies the port | The policy is deny-by-default once saved. Check it in the admin console — the template is `/etc/oma-stack/tailnet-policy.json` |
| `tailscale serve` hangs | `--bg` is missing | The kit always passes it; if you ran it by hand, use `tailscale serve --bg --https=443 http://127.0.0.1:3000` |
| The node key expired | Untagged nodes expire every 180 days | `sudo tailscale up --force-reauth`, or "Temporarily extend key" in the admin console |
| The tailnet name does not resolve | `--accept-dns=0` leaves the OS resolver alone | Check with `tailscale dns query oma.<tailnet>.ts.net`; set `TAILSCALE_ACCEPT_DNS=1` and re-run `tailscale up` |
| OpenBot is not reachable on the tailnet address | The publish file is missing | `oma serve refresh` writes `components/openbot/docker-compose.override.yml` and restarts OpenBot |
| Forgejo's links point at 127.0.0.1 | `ROOT_URL` was not re-pointed at the tailnet name | `oma serve refresh` rewrites `ROOT_URL`, `DOMAIN` and `SSH_DOMAIN` and restarts Forgejo |

The full tailnet guide, including the per-device install matrix and the key
expiry procedure, is in [TAILNET.md](TAILNET.md).

---

## 9. Undo

```bash
sudo /opt/oma-stack/uninstall.sh           # stop the services, keep the data
sudo /opt/oma-stack/uninstall.sh --purge   # and delete the data
```

`--purge` removes `/etc/oma-stack`, `/var/lib/forgejo`, `/var/lib/oma-stack`
and the `oma-openbot-data`, `oma-openbot-workspace` and `oma-openbot-profiles`
volumes. **GitHub is never touched.**

---

## 9. The weekly check

```bash
sudo /opt/oma-stack/verify/healthcheck.sh
df -h /var/lib/forgejo /mnt/usb
sudo du -sh /var/lib/forgejo/actions-artifacts
```

Nothing grows without a bound. Actions artifacts are the usual culprit — prune
them if the SSD fills:

```bash
sudo find /var/lib/forgejo/actions-artifacts -type d -mtime +30 -exec rm -rf {} +
```

---

## 10. Re-running the installer

Safe at any time. Every step checks whether it already did its job, and every
secret that already exists is kept.

```bash
cd /opt/oma-stack
git pull
sudo ./install.sh
```

Your edits to `/etc/oma-stack/host.env` are preserved: the installer never
overwrites an installed config that already exists.
