# Contributing

The kit is one operator's infrastructure, and it stays that way. Changes are
small, tested, and reversible.

## Run the tests

```bash
bash tests/harness.sh                      # the functional harness
python3 -m unittest discover -s tests      # the bridge unit tests
```

Both must pass before a change is proposed.

The harness runs against local fakes — real bind mounts, real bare git repos,
a real sqlite database, a stub GitHub. No root, no docker, no network beyond
the stub. It exercises the mirror, the issue snapshot, the backup, the
three-state healthcheck, the installer wiring, and the bridge end to end.

The unit tests cover the bridge: the registry, the routing chain, the AG-UI
events, the handoff queue and the allowlist.

## Shellcheck

```bash
shellcheck -S error $(find . -name '*.sh' -not -path './.git/*') bin/oma
```

`-S error` is the bar, and it is the bar the repo already meets. The default
severity reports noise nobody has fixed — mostly the sourced files shellcheck
cannot follow (`SC1090`, `SC1091`) — so do not lower the gate to make a run
look clean. Fix the file you touched instead.

## Style

- **Comments explain WHY.** Never a comment that restates the code. If the
  line says what it does, the comment has to say what it costs, what breaks
  without it, or which upstream behavior it works around.
- **American spelling.** Match the file you are editing: color, behavior,
  initialize. Be consistent within a change, even if a neighboring file
  slips.
- **Short lines. Tables where things are compared.** Prose everywhere else.
- **No emoji, no exclamation marks.** The brand is quiet on purpose.
- **The same words everywhere.** If the README calls it the agent bridge, so
  do the docs, so do the CLI output.

## The approval rule

The kit never merges, deploys, activates a workflow, or changes credentials
or billing without explicit authorization. Not from a script, not from an
agent, not from a pull request that asks nicely.

This is the agent-library's canonical decision #26: *require explicit approval
before merges, deployments, workflow activation, credential/billing changes,
paid or destructive actions.* The bridge enforces the same rule at runtime: it
runs an agent, writes the answer to the outbox, and waits for a human.

The mirror is the other half of it: GitHub to Forgejo, one way. The mirror
reads. It never pushes, never opens a pull request, never closes an issue.

## Commits

Short, imperative subject. The body says why, not what.

```
make the entry points executable
let the bridge read its own registry
```

## Releases

The version lives in three places and they move together:

1. `VERSION`
2. `OMA_VERSION` in `bin/oma`
3. `__version__` in `components/agents/bridge.py`

Two more carry the number as well: the footer in `site/index.html`. The
install banner in `install.sh` reads `VERSION` at runtime, so it cannot
drift. Update the footer too, or it will lie.

Then update `CHANGELOG.md` with the section for the new version, and cut the
release:

```bash
gh release create v1.2.0 --title "v1.2.0" --notes-file <the 1.2.0 section of CHANGELOG.md>
```

Tag the release commit, push the tag, and check the install path once more on
a machine that has nothing installed:

```bash
curl -fsSL https://raw.githubusercontent.com/MartinMayday/oma-stack/main/bootstrap.sh | sudo bash
oma doctor
```
