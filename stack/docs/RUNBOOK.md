# RUNBOOK — what to do when GitHub blocks the pipeline

This is the document to read at 2am when a workflow will not start.

Read the first section only if you are in a hurry. Everything else is reference.

---

## 1. The 60-second triage

```bash
# 1. Is GitHub the problem, or is the workflow?
gh run list --repo MartinMayday/agent-library --limit 5

# 2. If every run says "startup_failure", GitHub never even parsed your YAML.
#    That is the account lock, not your code.
gh api repos/MartinMayday/agent-library/commits/main/check-suites \
  --jq '.check_suites[] | "\(.app.slug) \(.status)/\(.conclusion)"'

# 3. Is the fallback alive?
sudo /opt/oma-stack/verify/healthcheck.sh
```

**Decision table:**

| Symptom | Cause | Action |
|---|---|---|
| `startup_failure`, zero jobs, on **every** repo | Account billing lock | Fall back to Forgejo (section 3). Fix billing (section 5). |
| `startup_failure` on **one** repo only | Workflow file invalid / Actions disabled for that repo | Check the repo's Actions tab. Local syntax check: `actionlint .github/workflows/*.yml` |
| Runs fine, one job fails | Your code / your test | Normal debugging. The pipeline is alive. |
| Job sits `queued` forever, hosted runner | Runner labels don't match | `runs-on:` says `ubuntu-latest` but the repo has no hosted runner access |
| Job sits `queued` forever, self-hosted | The MacBook runner is offline or its labels don't match | `systemctl status actions.runner.*` and check the labels |
| `startup_failure` + "account is locked" annotation | Confirmed billing lock | Section 3. |

---

## 2. The one thing to understand first

Measured on 2026-11-11 against this exact account:

```
github.com/MartinMayday/agent-library        (PRIVATE)
  any workflow, any runner  ->  startup_failure, zero jobs, workflow never registers

github.com/MartinMayday/agents-md-generator  (PUBLIC)
  runs-on: ubuntu-latest                     ->  job runs, conclusion=failure
  runs-on: [self-hosted, linux, x64]         ->  job QUEUES, waits for a runner
```

**The lock blocks Actions, not git.** You can still push, pull, tag, and branch.
Only job execution is affected, and only on private repos does it fail so early
that the workflow never registers at all.

That gives us exactly two fallback paths, and they are not alternatives — they
cover different repos.

---

## 3. Fall back to Forgejo (private repos)

### What still works on GitHub during the lock

Only **job execution** is refused. These all still work:

- pushing, pulling, branching, tagging
- creating a branch, opening a pull request, reviewing, merging
- issues, labels, comments, releases
- branch protection is unavailable on the Free plan anyway, so nothing blocks
  you from merging

So a private repo is not "down" during the lock. It is **down in exactly one
place: the CI run.** Forgejo supplies that one missing piece.

### The recommended flow

```bash
# 1. Work on GitHub as usual — nothing about git is blocked.
git switch -c fix/issue-42
git commit -am "fix(#42): what changed"
git push origin fix/issue-42

# 2. Open the PR on GitHub (this works too).
gh pr create --repo MartinMayday/agent-library \
  --title "fix(#42): what changed" --body "Closes #42"

# 3. Carry the branch to Forgejo so the runner can execute it.
sudo /opt/oma-stack/stack/mirror/mirror-sync.sh

# 4. Open the PR in Forgejo too (http://<lan-ip>:3000/ci-admin/agent-library).
#    The runner picks it up and runs the same workflow.
```

Step 3 is the only one that is not normal GitHub usage. It exists because the
mirror timer runs every 15 minutes and you want the CI evidence now, not in a
quarter of an hour.

The Forgejo run is the CI evidence your closure protocol needs. Reference it
in the GitHub PR or issue comment:

```
CI evidence: http://<lan-ip>:3000/ci-admin/agent-library/actions/runs/42
```

### The alternative — work entirely in Forgejo

If you would rather not bounce between two UIs:

```bash
git remote add forgejo http://<lan-ip>:3000/ci-admin/agent-library.git
git fetch forgejo
git switch -c fix/issue-42 forgejo/main
git commit -am "fix(#42): what changed"
git push forgejo fix/issue-42
```

Then open the PR in Forgejo. Your branch lives there. The mirror does **not**
prune, so it stays put.

**The catch:** a branch that exists only in Forgejo does not travel back to
GitHub on its own. When GitHub is usable again, push it there yourself:

```bash
git push origin fix/issue-42
```

Git is not blocked, so this always works.

### Mirror lag

Up to `MIRROR_INTERVAL_MIN` (15 by default). Run `mirror-sync.sh` manually
when you cannot wait.

---

## 4. Keep using GitHub CI for public repos

The MacBook is registered as a GitHub self-hosted runner, and self-hosted
dispatch survives the lock. Change the workflow's `runs-on:` to point at it:

```yaml
jobs:
  build:
    # was: runs-on: ubuntu-latest
    runs-on: [self-hosted, linux, x64]
```

Public repos then keep their full GitHub CI: PR checks, the Actions tab,
commit statuses, everything. Private repos cannot be rescued this way —
their workflows never register at all.

Note that the `closure-audit` workflow in the ops kit expects GitHub-hosted
semantics. On a self-hosted runner it still runs; it just runs on your laptop.

---

## 5. Unblock GitHub itself (the actual fix)

The lock clears when GitHub can charge a valid payment method. Full checklist
in `GITHUB-BILLING-CHECKLIST.md`. The short version:

1. https://github.com/settings/billing — add or update the card.
2. Confirm the card is not expired and the billing address matches.
3. Resolve any failed invoice or authorization hold (GitHub locks the account
   when a card charge bounces).
4. Check the spending limit / budget. A budget set to "stop usage" will keep
   jobs from starting even with a valid card.
5. Verify:

```bash
gh auth refresh -h github.com -s user
/opt/oma-stack/stack/verify/billing-check.sh
```

Then push a trivial workflow to a public repo and confirm it gets a
`success` conclusion.

**Until that happens, the fallback is not optional — it is the only thing
running private-repo CI.**

---

## 6. Manual closure policy (when GitHub is blocked)

The closure protocol in the ops kit assumes GitHub is answering. When it is
not, do not mark a ticket fixed on a promise.

Allowed while the lock is active:

- Push the fix and the branch to GitHub. Git operations work.
- Mirror the branch into Forgejo, open the PR there, let CI run there.
- Record the evidence chain in the issue as a comment.

Not allowed:

- Closing the issue with no green CI on the merge commit.
- Closing the issue because the change "looks right".
- Editing the GitHub workflow to force a green result.

When the lock clears, run the closure audit against every issue you closed
under the fallback, and reopen any that fail.

---

## 7. Common failures with a fix

**"Forgejo: workflow not found"** — the repo has `.forgejo/workflows/` which
shadows `.github/workflows/`. Forgejo uses the first directory that exists:
`.forgejo/workflows` -> `.gitea/workflows` -> `.github/workflows`. It does not
merge them. If your repo has a `.forgejo/workflows` directory, that is the one
that runs.

**"Forgejo: job stays queued"** — the runner labels do not match `runs-on:`.
The runner advertises `self-hosted:host linux x64`. A workflow asking for
`ubuntu-latest` will never match unless you enable the docker label in
`host.env` (`ENABLE_DOCKER_LABEL=1`).

**"Forgejo: `permissions:` block ignored"** — expected. Forgejo Actions is
"familiar, not compatible" with GitHub Actions. `job.permissions` and
`continue-on-error` are ignored. `matrix`, `services:` and `container:` do
work.

**"Mirror says push failed"** — the Forgejo repo may not exist yet. Run
`sudo /opt/oma-stack/stack/mirror/setup-mirrors.sh`.

**"The MacBook sleeps mid-job"** — the sleep inhibitor unit is not running:

```bash
systemctl status ci-sleep-inhibitor.service
systemctl is-enabled ci-sleep-inhibitor.service
```

**"Healthcheck says the USB disk is not mounted"** — this is a **WARN**, not a
failure. Nothing Forgejo needs lives on the USB disk, so CI, the mirror and the
tracker keep working. The only casualty is the backup job, which skips itself.

```bash
sudo mount /mnt/usb          # then the next backup run picks up again
systemctl list-timers 'oma-backup*'
```

**"Healthcheck says the internal SSD is nearly full"** — that one is a **FAIL**
and it matters. The repositories, the database, the Actions logs and the mirror
cache all live on the 128 GB SSD.

```bash
df -h /var/lib/forgejo
du -sh /var/lib/forgejo/*
```

Prune the oldest Actions logs and artifacts first — they are the bulk:

```bash
sudo find /var/lib/forgejo/actions-log -type f -mtime +14 -delete
sudo find /var/lib/forgejo/actions-artifacts -type f -mtime +14 -delete
```

**"The backup timer keeps failing"** — check the mount, then the last snapshot:

```bash
ls -lt /mnt/usb/backups/ | head
cat /mnt/usb/backups/.last-backup
sudo journalctl -u oma-backup.service -n 50
```

---

## 8. The MacBook's job description

It is a CI appliance, not a workstation. Keep it:

- plugged in to power
- on a wired network
- lid open or the sleep inhibitor running
- the USB SATA disk mounted (for backups only — CI runs without it)
- the SD card mounted for runner scratch (optional; it falls back to the SSD)

Your LLM providers (Qoder, Z.ai GLM Coding Plan, MiniMax) run *locally* on this
machine as the agent layer. CI only validates. That split is deliberate: the
agents do the implementation work, the runner does the checking, and neither
one consumes GitHub's billing.

---

## 9. Where things live

| Thing | Path |
|---|---|
| Package | `/opt/oma-stack/` |
| Editable config | `/opt/oma-stack/config/host.env` |
| Forgejo config | `/etc/forgejo/app.ini` |
| Forgejo DB | `/var/lib/forgejo/data/forgejo.db` (internal SSD) |
| Forgejo repos | `/var/lib/forgejo/forgejo-repositories` (internal SSD) |
| Actions logs | `/var/lib/forgejo/actions-log` (internal SSD) |
| Actions artifacts | `/var/lib/forgejo/actions-artifacts` (internal SSD) |
| Mirror cache | `/var/lib/forgejo/mirror-cache` (internal SSD) |
| Backups | `/mnt/usb/backups/<timestamp>/` (USB SATA) |
| Runner scratch | `/mnt/sd/act-work` (SD card, optional) → `/var/cache/forgejo-runner/work` |
| Credentials | `/etc/oma-stack/*.token` (mode 0600) |
| Health log | `/var/log/oma-stack-health.log` |
| Runner config | `/home/runner/runner-config.yml` |
| GitHub runner | `/opt/actions-runner/` |
