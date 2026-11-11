# stack/ — the Forgejo + CI layer

This is the part of `oma-stack` that existed before OpenBot and the agent
bridge: a working CI box for a machine whose GitHub account cannot start a
single hosted job.

It is a self-contained package. It installs Forgejo, registers the Forgejo
Actions runner and the GitHub self-hosted runner, mirrors GitHub into Forgejo,
snapshots the issue tracker, and backs the hot tier up to the USB disk.

**You do not normally install this on its own.** The kit's `install.sh` calls
`stack/install.sh` for you. Run that instead:

```bash
sudo /opt/oma-stack/install.sh
```

---

## What it does

| Capability | Where it runs | Blocked by the GitHub lock? |
|---|---|---|
| git push / pull / branch / tag | GitHub | **No** — git is unaffected |
| public-repo CI | GitHub + the MacBook as a self-hosted runner | **No** — proven by probe |
| private-repo CI | Forgejo on the MacBook | **No** — Forgejo has no billing gate |
| issues, PRs, code review | GitHub (canonical) + Forgejo (mirror) | No |

GitHub stays the source of truth. Forgejo is where the work happens when
GitHub cannot.

---

## Layout

```
stack/
├── install.sh                    runs every step in order
├── install/
│   ├── 00-preflight.sh           check the hardware and the disks
│   ├── 10-forgejo.sh             server, database, admin user
│   ├── 20-forgejo-runner.sh      the CI executor
│   ├── 30-github-runner.sh       GitHub self-hosted runner
│   ├── 40-exposure.sh            LAN / Tailscale / Caddy
│   ├── 50-always-on.sh           lid switch, sleep, docker limits
│   ├── 60-timers.sh              systemd timers
│   └── 70-backup.sh              backup timer
├── mirror/
│   ├── setup-mirrors.sh          one-time repo creation
│   ├── mirror-sync.sh            GitHub -> Forgejo, every 15 min
│   └── issue-snapshot.sh         read-only issue snapshot
├── backup/
│   └── backup-to-usb.sh          snapshot the hot tier to the USB disk
├── verify/
│   ├── healthcheck.sh            is this layer alive?
│   ├── selftest.sh               push a workflow, prove it runs
│   └── billing-check.sh          what does GitHub think of the account
├── templates/                    workflow templates to copy into a repo
└── docs/
    ├── ARCHITECTURE.md           why it is built this way
    ├── RUNBOOK.md                what to do when GitHub blocks you
    ├── WORKFLOWS.md              the workflow YAML
    └── GITHUB-BILLING-CHECKLIST.md
```

The one config file for the whole kit is `/etc/oma-stack/host.env`. Every
script here reads it.

---

## Storage rules

| Disk | Holds | Never holds |
|---|---|---|
| 128 GB internal SSD | OS, Forgejo DB, **repositories**, Actions logs + artifacts, mirror cache, Docker data-root, runner work | — |
| 4 TB USB SATA | dated backup snapshots only | **anything Forgejo needs to run** |
| 512 GB SD card | optional runner scratch | **the database, the repos, ever** |

The USB disk is *not* a dependency. Unplug it and CI, the mirror and the
tracker keep running — only the backup job skips itself. The healthcheck
reports that as a **WARN**, not a failure.

Backups run every 6 hours to `/mnt/usb/backups/<timestamp>/`, keeping the
newest 7. Each snapshot carries a `RESTORE.sh`.

---

## One thing to know before you read the code

The mirror only ever runs **one way** — GitHub into Forgejo. It never runs
`git push --mirror`, because that would delete GitHub branches that do not
exist in Forgejo. GitHub is never a push target, so the mirror can never
damage it.

Work done in Forgejo does not travel back automatically. Push it to GitHub
yourself when you are ready — git is not affected by the lock, so that always
works.

---

## Versions

Forgejo 17.0.1-1 (Arch `extra`) · forgejo-runner 13.2.1 · GitHub Actions
runner 2.338.2. Pinned in the install scripts.

### 1.1.0 — internal-SSD storage tiering

- The hot tier (DB, repositories, Actions logs + artifacts, mirror cache)
  moved from the USB SATA disk to the internal PCIe SSD. The USB disk is now
  backups only, and is no longer a dependency of any running service.
- New `backup/backup-to-usb.sh` + systemd timer: dated snapshots every 6 h,
  7 kept, each with a `RESTORE.sh`.
- The healthcheck gained a third state. A missing USB disk is now a **WARN**;
  a full internal SSD is a **FAIL**.
- The SD card is now optional runner scratch with an automatic fallback to
  the SSD when it is not inserted.
- Fixed: `FF_FAKE_FORGEJO` now works for more than one repository.
