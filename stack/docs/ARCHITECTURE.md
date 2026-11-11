# ARCHITECTURE — what the fallback actually is, and why

## The problem being solved

GitHub Actions on the account `MartinMayday` is blocked by a **billing lock**.
GitHub's own annotation on the failing jobs:

> "The job was not started because your account is locked due to a billing issue."

Scope, measured on 2026-11-11: 154 repositories owned (52 private, 102 public),
15 with any workflow runs, 4,511 runs, **zero successful runs ever**, earliest
run 2025-11-06. Not one workflow in the account has ever completed. This is
not a broken YAML file and it is not a broken workflow — it is the account.

The fallback has one job: **keep the pipeline running when GitHub says no.**

---

## The three measured facts that determine the design

These were established by direct experiment, not from documentation. Everything
else follows from them.

### Fact 1 — the lock blocks Actions, not git

Pushes, pulls, branches, tags, and PRs all work normally. Only job execution
is refused. That is why a mirror is possible at all, and why GitHub can stay
the canonical remote.

### Fact 2 — self-hosted runners are not blocked

Public repo `MartinMayday/agents-md-generator`, one workflow, two jobs:

```
job 'hosted'     status=completed  conclusion=failure   runner=''          labels=['ubuntu-latest']
job 'selfhosted' status=queued     conclusion=         runner='None'      labels=['self-hosted','linux','x64']
```

The hosted job was refused by the lock. The self-hosted job **queued and
waited for a runner**. The lock does not block self-hosted dispatch.

GitHub's pricing docs confirm the reasoning: "Self-hosted runners" are listed
under usage that "remains free independently and does not reduce the included
compute usage." A self-hosted runner consumes no metered compute, so there is
nothing for the lock to refuse.

**Consequence:** registering the MacBook as a GitHub self-hosted runner keeps
**public-repo** CI fully alive on GitHub itself — PR checks, the Actions tab,
commit statuses, all of it.

### Fact 3 — private repos cannot be rescued by any runner

Private repo `MartinMayday/agent-library`, same experiment:

```
run name=''  status=completed  conclusion=startup_failure  jobs=[] 
```

Zero jobs. The workflow never registered at all — it failed before any job
could be created, so the `runs-on:` value was never consulted. Adding a
self-hosted runner does not help. Adding a hosted runner does not help.

**Consequence:** private repos need a forge that has no billing gate.

---

## The topology

```
                    ┌──────────────────────────────────────────┐
                    │            GitHub (canonical)            │
                    │  git + issues + PRs + public-repo CI      │
                    │                                          │
                    │  public repos  ──► self-hosted runner    │
                    │                      (MacBook)  ✔ works   │
                    │                                          │
                    │  private repos ──► startup_failure  ✘     │
                    └──────────────────┬───────────────────────┘
                                       │
                          git mirror (one way, 15 min)
                                       │
                    ┌──────────────────▼───────────────────────┐
                    │        MacBook Pro 2014 (Arch/Omarchy)    │
                    │                                          │
                    │   Forgejo ── git + issues + PRs + CI       │
                    │      ▲                                   │
                    │      │ act_runner / forgejo-runner        │
                    │      │                                   │
                    │   agent layer (local):                   │
                    │      Qoder · Z.ai GLM · MiniMax          │
                    └──────────────────────────────────────────┘
```

**GitHub stays canonical.** It is where the code is written, where issues
live, and where public-repo CI runs. The fallback is a second execution path,
not a second source of truth. Nothing in this package ever writes back to
GitHub.

---

## Why Forgejo and not GitLab

| | Forgejo | GitLab self-hosted |
|---|---|---|
| RAM on this box | ~300 MB | 2–4 GB |
| Install on a 2014 MBP | one package | systemd units + reverse proxy tuning |
| Actions compatibility | "familiar, not compatible" | closer to GitHub Actions |
| Licence | MIT | core is MIT, EE features are not |

At 8 GB of RAM with the desktop also running, Forgejo is the only one of the
two that fits comfortably. Its Actions runner is *not* a drop-in for GitHub
Actions, and the package treats that as a known limitation rather than
pretending otherwise.

---

## Storage layout — three disks, three jobs

| Device | Contents | Why |
|---|---|---|
| **128 GB SSD** (internal PCIe) | OS, Forgejo SQLite DB, git repositories, Actions logs, Actions artifacts, mirror cache, Docker data-root, runner work | Everything hot. The whole working set is small — `agent-library` is 12 MB — so the fast, durable disk holds it all. No mount dependency, no slow path. |
| **4 TB USB SATA** | Dated backup snapshots only | Bulk and cold. Nothing Forgejo needs in order to run, so an absent USB disk is never fatal — only backups stop. |
| **512 GB SD card** | Optional runner scratch (`workdir_parent`) | Consumer SD has no wear-levelling guarantee. Fine for throwaway job workspaces, wrong for anything you care about. Auto-detected: when the card is absent the runner falls back to `/var/cache/forgejo-runner/work` on the SSD. |

**The database is never on the SD card. The repositories are never on the
SD card.**

### Why the repositories moved off the USB disk

They were on the USB SATA in v1.0.0. That was wrong for this workload:

| | Internal PCIe SSD | 4 TB USB SATA | 512 GB SD card |
|---|---|---|---|
| Sequential | ~500 MB/s | ~120–160 MB/s | ~40–90 MB/s (Retina) |
| Random 4K write | ~0.1–0.3 ms | ~8–12 ms | ~5–20 ms, **~0.3–1 MB/s** |
| Seek | n/a (flash) | ~8 ms | n/a (flash) |
| Endurance | high | high | low (SLC write cliff) |
| Dependency | none | mount required | mount required |

Three facts settled it:

1. **Size.** The whole mirror set is ~12 MB. The 4 TB disk is 300× larger than
   the data. Capacity is not the constraint.
2. **Speed.** Git is not sequential. A mirror push does thousands of small
   writes and the SQLite DB does random writes behind it. USB-SATA random
   writes are ~50× slower than the internal PCIe SSD. Putting the hot set on
   the slower disk bought nothing.
3. **Failure mode.** `RequiresMountsFor=/mnt/usb` made the *database* depend on
   a pluggable disk. Every unplug was a risk event for a 12 MB dataset.

The USB disk keeps the job it is actually good at: cheap, roomy, cold storage
for dated backups.

### The mount trap (now optional)

The Arch-packaged `forgejo.service` runs with `ProtectSystem=strict`. If a
path is not mounted when the service starts, Forgejo happily writes into the
*root filesystem* — silently filling the 128 GB SSD with data that will be
invisible once the disk mounts.

v1.0.0 guarded against this with a permanent drop-in:

```ini
[Unit]
RequiresMountsFor=/mnt/usb

[Service]
ReadWritePaths=/mnt/usb /mnt/usb/forgejo/forgejo-repositories ...
```

In v1.1.0 the drop-in is **conditional**: it is only written when
`USB_HOLDS_ACTIONS=1` (the opt-in that puts Actions logs and artifacts on the
USB disk). By default it is removed, so Forgejo has no USB dependency at all.

The USB disk is still guarded for the backup job, which does use
`RequiresMountsFor=${USB_DISK}` — but a failed backup does not stop CI.

The healthcheck reports a missing USB mount as a **WARN**, not a FAIL. It
reports a full internal SSD as a **FAIL**, because that one is fatal.

### Backups

`backup/backup-to-usb.sh` runs every `${BACKUP_INTERVAL_H}` hours (default 6)
and writes a dated snapshot to `${BACKUP_ROOT}/<timestamp>/`:

- the Forgejo DB via `sqlite3 .backup` — a transactionally consistent copy
  taken with a read lock, no downtime
- `forgejo-repositories`, `actions-log`, `actions-artifacts` and
  `mirror-cache` as tar.gz archives
- `app.ini` (mode 0600 — it contains secrets)
- `MANIFEST.txt` and a ready-to-run `RESTORE.sh`

Snapshots are published atomically (built in `<timestamp>.partial`, then
renamed) and pruned to `${BACKUP_RETENTION}` copies (default 7). A killed run
leaves a `.partial` directory, which the next run removes.

---

## The runner: host label, not docker

The runner advertises `self-hosted:host linux x64`.

- `self-hosted:host` means jobs run directly on the MacBook with no container.
  No image pull, no cgroup overhead, no second copy of Python.
- `linux` and `x64` are what let a GitHub-style `runs-on: [self-hosted, linux, x64]`
  match the runner. Without them, nothing queued.
- `capacity: 1` because the CPU has 2 cores / 4 threads and the desktop shares
  them.

A docker label (`ubuntu-latest:docker://ghcr.io/catthehacker/ubuntu:act-22.04`)
is available via `ENABLE_DOCKER_LABEL=1` in `host.env`. It is off by default
because it costs ~1 GB of image pull and ~2 GB of RAM on a machine that has
8 GB total.

---

## The agent layer

Qoder, Z.ai GLM Coding Plan and MiniMax run **locally** on the MacBook. They
are the implementation layer: they read the issue, write the fix, regenerate
derived artifacts, and push the branch.

CI does not call an LLM. CI validates. That separation is what makes the
fallback cheap and what keeps it off GitHub's billing entirely — a self-hosted
runner is free, and local inference is free.

```
issue ──► agent layer (local, Qoder/GLM/MiniMax) ──► branch + commit
                                                          │
                    ┌─────────────────────────────────────┘
                    ▼
        runner executes the validation workflow
                    │
                    ▼
        green check on the merge commit ──► issue closed
```

---

## Mirror direction is one-way, on purpose

The mirror pushes GitHub → Forgejo. It is **not** configured to push back.

The reason is concrete: Forgejo's push-mirror feature uses `git push --mirror`
when no branch filter is set. `--mirror` copies every ref and **deletes** every
remote branch that does not exist locally. Configure it wrong and it deletes
your GitHub branches.

So the package pushes two explicit refspecs instead:

```
+refs/heads/*:refs/heads/*
+refs/tags/*:refs/tags/*
```

Forgejo can only ever receive GitHub branches and tags. It can never delete
anything on GitHub, because GitHub is never a push target.

Two details worth knowing:

**The `+` prefix (force).** The Forgejo side is a mirror, so GitHub is
authoritative and the Forgejo side must be reset to match. Without force, a
branch that diverged — a GitHub force-push, or the repo's initial commit —
would make every subsequent sync fail forever. With force, the sync always
converges on GitHub's state.

**No `--prune`.** A branch that exists only in Forgejo (a fix you pushed
there during the outage) is left alone rather than deleted. The cost is that a
branch deleted on GitHub lingers in Forgejo until you delete it there too.
That trade is deliberate: losing a fix branch to a background timer is much
worse than carrying a stale branch.

The cost of one-way is that work done directly in Forgejo does not flow back.
That is correct: GitHub is canonical. If you need to land a change made in
Forgejo, push it to GitHub yourself — git is not affected by the lock, so that
always works.

---

## What the fallback does NOT give you

Being explicit about the gaps:

- **GitHub branch protection on private repos.** Plan-gated. The API returns
  "Upgrade to GitHub Pro or make this repository public to enable this
  feature." That is a separate wall from the billing lock and it does not go
  away with a card on file on the Free plan. The closure audit workflow
  enforces the gate instead of branch protection.
- **GitHub-hosted runners.** Refused while the lock is on. Use the
  self-hosted runner.
- **Continuous issue sync.** GitHub issues are not git refs. The package
  publishes a read-only JSON snapshot on a timer instead.
- **GitHub Pages, releases, or the GitHub PR UI** for private repos. Forgejo
  has its own.
- **Bit-for-bit GitHub Actions compatibility in Forgejo.** `job.permissions`
  and `continue-on-error` are ignored. `matrix`, `services:` and `container:`
  do work.

---

## The Omarchy question

Omarchy **does** support Intel Macs — that is confirmed by the official
manual ("Omarchy has built-in support for Intel Macs"), and a 2014 MacBook
takes the plain Intel path with no T1/T2 special-casing.

Two caveats for this specific use:

1. The installer **wipes the boot disk** and macOS stops being bootable. On a
   128 GB SSD that is also the Forgejo database disk, so have the USB SATA
   disk connected and know your backup situation before running it.
2. Omarchy is a desktop image. It adds no CI capability over plain Arch. If
   the machine is a CI appliance, plain Arch is the simpler base; if it is
   also your workstation, Omarchy is fine.

The package does not care which you chose. It only assumes `systemd`,
`pacman` or `apt-get`, and `x86_64`.

---

## Timeline of the diagnosis

| Date | Finding |
|---|---|
| 2026-11-11 | 221 runs in `agent-library`, all `startup_failure`, all bound to a deleted synthetic sentinel entity. Live workflow entity had received zero runs. |
| 2026-11-11 | Ruled out: malformed YAML, bad tree modes, bad action SHAs, Actions disabled, token permissions, workflow content, workflow path and name. |
| 2026-11-11 | Control test in a public repo returned GitHub's own annotation: the job was not started because the account is locked due to a billing issue. |
| 2026-11-11 | Account-wide scope: 154 repos, 4,511 runs, zero successes, earliest 2025-11-06. |
| 2026-11-11 | Self-hosted dispatch probe: public repo self-hosted job **queued** while hosted job failed. Private repo: workflow never registered. |
| 2026-11-11 | Probe branches deleted from both repos. |
| 2026-11-11 | This package built. |

---

## Provenance

- Forgejo 17.0.1-1 (Arch `extra`), runner 13.2.1, GitHub runner 2.338.2 —
  versions pinned in the install scripts.
- The Arch package ships its own systemd unit with `User=forgejo` and
  `ProtectSystem=strict`. The upstream contrib unit uses `User=git` and must
  **not** be used — the package uses the packaged unit.
- The runner binary is hosted on `code.forgejo.org`, not codeberg.
- The runner has no default config path: `-c` is mandatory.
- Forgejo Actions discovers workflows in `.forgejo/workflows` →
  `.gitea/workflows` → `.github/workflows`, first existing directory wins.
  It does not merge them.
- The underlying research spec, with primary-source citations for every
  version, path, config key and API field, is `fallback-ci-forge-spec.md`.
