# ADR-0002: The agent routing chain is serial and runs qoder, glm, minimax, echo

- **Status:** accepted
- **Date:** 2026-11-11
- **Deciders:** MartinMayday (owner), Qoder (CTO/architecture)

## Context

The agent-library repository contains no default agent and no canonical
runtime routing order. It holds six competing ordering artefacts — a
task-shape-to-harness table, a tool router, review lanes, an ecosystem
deduplication priority — that disagree in scope. `PRIORITY.md` is a
conversion (build) order for turning persona guides into profiles, not a
runtime router. The repository publishes no agent-registry record for any of
the three CLIs the kit drives, so the kit has to assemble the runtime order
itself.

The order is a technical decision, and the owner delegated it.

The commands must be ones the agent-library's own receipts prove work:
`qoder -p --no-session-persistence "<prompt>"`
(`catalogs/skills/canonical/qoder-bridge/SKILL.md:57`), `claude -p "<prompt>"`
on `zai/glm-5.3`
(`sessions/labs/staging/WI-006-smart-ai-router-angr8/Cases/angr8-003-lang-gate-router/ops/VERIFICATION.md:100`),
and `codex exec --skip-git-repo-check -m minimax-io/MiniMax-M3.1-Flash
"<prompt>"` (the same case's `receipts/2026-11-07-upgrade-v250.md:32`).

The box has 2 cores and 8 GB RAM, shared with the desktop.

## Decision

The agent registry (`components/agents/agents.json`) ships a chain:
`qoder → glm → minimax → echo`. The head of the chain is the default.

- The default agent answers first. If it fails, the next agent in the chain
  takes over, in order.
- The AG-UI reply carries the name of the agent that actually answered
  (`"agent": "<name>"` on `RUN_FINISHED`), and the handoff audit log records
  the fallback.
- The chain is serial, not parallel. Two model calls at once on 2 cores
  starve each other.
- The installer detects which binaries are on the PATH, disables the entries
  that are not runnable, and picks the first runnable agent as the default.

## Consequences

### Good

- One endpoint per agent, one ordered fallback: the answer arrives even when
  the preferred agent is missing or broken.
- The commands are proven, not invented, so the first agent that runs is
  likely to run at all.
- An agent that is not installed is a normal state; it keeps its name and is
  disabled rather than failing the chain.
- Every answer says who produced it, so a fallback is visible in the audit
  trail and not just in the output.

### Bad

- A serial chain is slower than a fan-out when the first agent fails: the
  failure is paid for in full before the fallback starts.
- Only one agent can work at a time, so a long job blocks every other
  request the bridge takes.
- The chain order is a judgment about which agent is best; the repository
  offers no evidence that it is right.

### Neutral

- The `echo` entry exists so the bridge can be proved working before a real
  agent is wired up.
- `qoder -p` can exit 0 on an error, so the exit code alone is not proof of
  success; the reply is read as text.
- Timeouts are 1800 seconds per real agent and 60 seconds for `echo`.

## Alternatives considered

- **Asking the owner to choose the order** — it is a technical decision and
  the owner delegated it; the kit has to ship a working default.
- **Parallel fan-out** — no headroom on this hardware, and two concurrent
  model calls would starve each other.
- **An invented primary agent** — the repository defines no such concept, so
  the chain is the kit's own construct and is recorded as one.
