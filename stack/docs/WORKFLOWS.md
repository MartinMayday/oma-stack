# Workflow templates for the fallback

## How Forgejo finds workflows

Forgejo Actions looks for workflows in this order and uses the **first
directory that exists**:

1. `.forgejo/workflows/`
2. `.gitea/workflows/`
3. `.github/workflows/`

It does **not** merge them. If a repo has `.forgejo/workflows/`, the
`.github/workflows/` files are ignored entirely.

Your repos already have `.github/workflows/`, and the mirror copies them
across, so **Forgejo will run the GitHub workflows as-is** with no changes.
That is the default and you should leave it that way.

Create `.forgejo/workflows/` only when you need a workflow that behaves
differently under Forgejo — for example a CI job that skips a step GitHub
Actions handles natively.

---

## What Forgejo ignores

Forgejo Actions is "designed to be familiar, but not designed to be
compatible" with GitHub Actions. Known differences:

| Feature | Forgejo | GitHub Actions |
|---|---|---|
| `job.permissions` | **ignored** | enforced |
| `continue-on-error` | **ignored** | honoured |
| `matrix` | supported | supported |
| `services:` | supported | supported |
| `jobs.<id>.container` | supported | supported |
| `actions/cache` | supported (own cache server) | supported |
| OIDC | `enable-openid-connect` | `permissions: id-token: write` |
| default job image | Debian bookworm + node | ubuntu-latest |
| `self-hosted` | label type `host` | label type `host` |

Third-party marketplace actions may fail to resolve. The first-party ones
(`actions/checkout`, `actions/setup-python`) work.

---

## `forgejo-ci.yml` — a CI job tuned for this MacBook

Copy into a mirrored repo as `.forgejo/workflows/forgejo-ci.yml` **only if**
you want Forgejo-specific behaviour. Otherwise leave `.github/workflows/`
alone and let Forgejo use those.

```yaml
name: forgejo-ci

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  validate:
    runs-on: [self-hosted, linux, x64]
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.11'

      - name: Run the repo's own validation
        run: |
          if [ -f Tools/validate-scaffold.py ]; then
            python3 Tools/validate-scaffold.py
          elif [ -d tests ]; then
            python3 -m pytest tests/ -q
          else
            echo "nothing to validate — define the command here"
          fi
```

`runs-on: [self-hosted, linux, x64]` is what the runner on the MacBook
advertises. A `ubuntu-latest` label will sit queued forever unless you enable
the docker label in `host.env`.

---

## `github-self-hosted.yml` — keeping GitHub CI alive for public repos

Public repos can keep running on GitHub itself, because self-hosted dispatch
survives the billing lock. Change `runs-on:` and nothing else:

```yaml
jobs:
  validate:
    # was: ubuntu-latest
    runs-on: [self-hosted, linux, x64]
```

Full GitHub PR checks, the Actions tab, commit statuses — all of it stays on
GitHub. Only the compute moves to the MacBook.

This does **not** work for private repos. Their workflows never register
while the account is locked, whatever the `runs-on:` says.

---

## A note on the closure audit

The `closure-audit` workflow in the ops kit runs `scripts/verify_closure.py`
and publishes a verdict as an issue comment. It uses `gh issue comment`, which
needs a token with the right scopes in the runner environment. On the
self-hosted runner, either:

- pass `GH_TOKEN` / `GITHUB_TOKEN` into the job environment, or
- let the workflow use the built-in `github.token` (which is what the current
  version does — it has `issues: write` and `pull-requests: read`).

Under Forgejo the `gh` CLI is not present by default. The workflow will fail
at the publish step, not at the audit step. The audit result is still in the
job log and in `closure-report.json`, which is the part that matters.
