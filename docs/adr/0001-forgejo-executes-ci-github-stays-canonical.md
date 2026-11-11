# ADR-0001: Forgejo executes CI while GitHub stays the canonical remote

- **Status:** accepted
- **Date:** 2026-11-11
- **Deciders:** MartinMayday (owner), Qoder (CTO/architecture)

## Context

The `MartinMayday` GitHub account is billing-locked. Measured on 2026-11-11
(`stack/docs/ARCHITECTURE.md`): 154 repositories owned, 15 with any workflow
runs, 4,511 runs, zero successful runs ever, earliest run 2025-11-06.

Three measured facts shape everything else.

- The lock blocks job execution, not git. Pushes, branches, issues and pull
  requests all work.
- Public-repository workflows on `runs-on: ubuntu-latest` fail with GitHub's
  own annotation: "The job was not started because your account is locked due
  to a billing issue."
- Private-repository workflows never register at all: `startup_failure` with
  `jobs=[]`, before `runs-on` is ever consulted.

The lock cannot be lifted from here. A debit card is the only payment method
available, and GitHub's charges against it are what fail. That makes the
lock unfixable in this environment and unbounded in time.

Constraints: the owner wants GitHub to stay canonical (existing workflows,
pull request links and issue history live there), the kit must not spend
money, and the box is a 2014 dual-core i5 with 8 GB RAM and a 128 GB SSD.

## Decision

GitHub remains the source of truth for git, issues and pull requests.
Forgejo runs the CI jobs and holds an offline, one-way mirror of the
repositories.

- Public-repository CI keeps running on GitHub itself through a self-hosted
  runner registered for every repository the account owns
  (`stack/install/30-github-runner.sh`). Self-hosted runners consume no
  metered compute, so the lock does not refuse them; the public-repo job
  queues for the runner and runs.
- Private repositories get their CI from Forgejo, which has no billing gate.
  `stack/mirror/mirror-sync.sh` pushes two explicit refspecs, GitHub to
  Forgejo, and never pushes back.
- Git remotes stay on GitHub, so the IDE and the CLI need no change.

## Consequences

### Good

- Public-repository pull request checks stay on GitHub, where the owner
  already reads them.
- Private repositories get CI again, on a forge that does not ask for a card.
- No money is spent and no source code leaves the box.
- The mirror is one-way with explicit refspecs, so a misconfigured sync
  cannot delete a GitHub branch.

### Bad

- Two CI systems to reason about; a workflow change can need work in two
  places.
- Private-repository issues live in Forgejo, so the owner reads two trackers.
- The self-hosted runner occupies the same 2 cores as the desktop, and its
  capacity is deliberately 1.
- Forgejo Actions is not GitHub Actions: `job.permissions` and
  `continue-on-error` are ignored.

### Neutral

- The lock and the mirror are independent. The mirror keeps working if the
  lock clears, and the lock never affects git.
- GitHub issues are not git refs, so the kit publishes a read-only JSON issue
  snapshot on a timer rather than live issue sync.
- The runner advertises `self-hosted:host linux x64`, so jobs run directly on
  the box with no container overhead.

## Alternatives considered

- **Waiting for GitHub billing to be fixed** — unfixable from here and
  unbounded in time; the kit could not ship a CI path at all.
- **Moving the canonical repositories to Forgejo** — breaks the owner's
  existing workflows, pull request links and GitHub issue history, and the
  owner explicitly wants GitHub canonical.
- **A hosted CI service** — costs money and hands the code to a third party,
  against the own-your-hardware premise the kit is built on.
