# ADR-0005: One OpenBot image, and the upstream corrections it forced

- **Status:** accepted
- **Date:** 2026-11-11
- **Deciders:** MartinMayday (owner), Qoder (CTO/architecture)

## Context

OpenBot (CopilotKit/OpenBot) in its source deployment wants Bun, its own
PostgreSQL and more services than a 2-core, 8 GB laptop can hold: the app,
the server, the agent-computer, the agent-bot, the supervisor and PostgreSQL.

Upstream publishes an all-in-one image that carries the app, the API, the
browser the Bots drive and an embedded PostgreSQL on one port. That fits the
box; the source deployment does not.

The image is also not the source deployment, and the differences are the
decisions this record fixes. Upstream's computer policy is CEL, keyed on
`intent`, and the tool that runs a shell command is `computer_run_command`
(`server/src/computer/policy-translate.ts`). The image ships no scheduler,
though upstream keeps its routines sweep and its staged-attachment sweep as
scripts something outside the server has to run.

## Decision

The kit runs one pinned image, `ghcr.io/copilotkit/openbot:v1.0.2`, with
`EMBEDDED_POSTGRES=on` and one published port.

The corrections that came with that choice, each traceable to upstream:

- The image ships no Bot, so a model key is only needed for OpenBot's own
  Bots and is not a boot blocker. The boot blockers are the Intelligence
  coordinates, `KEY_ENCRYPTION_KEY` and `OPENBOT_SINGLE_USER`.
- `AGENT_COMPUTER_POLICY` denies on `intent == "run_command"`, because the
  tool upstream actually uses is `computer_run_command`. The kit's earlier
  deny on a tool named `computer_shell` never fired, which is worse than no
  rule at all.
- `/workspace` and `/profiles` are volumes. Without them every redeploy
  deletes the Bot files and logs the Bots out of every site.
- The image ships no scheduler, so the kit installs an hourly timer that runs
  the routines sweep and the staged-attachment sweep inside the running
  container, where the server's own environment applies.
- The stall watchdog is raised from the upstream 60 second default to 300
  seconds, and the bridge sends a heartbeat, because a CLI agent is silent
  for the whole model latency.
- `AGENT_ENDPOINT_ALLOWED_HOSTS` takes host or host:port with no scheme and
  no wildcards; a URL or a `*` stops OpenBot from starting. The registered
  agent URL is therefore `http://host.docker.internal:8765/ag-ui/<name>`,
  because inside the container `127.0.0.1` is the container.

## Consequences

### Good

- One container on one port, with the database inside it: no Bun toolchain
  and no second PostgreSQL on the box.
- The policy that refuses destructive shell commands now matches the tool
  upstream really calls, so it can fire.
- Bot files and signed-in browser sessions survive a redeploy.
- Routines fire and staged attachments are swept, which the image alone
  would never do.

### Bad

- The sweeps run inside the server container, so they are only as available
  as the container.
- Pinning the image means an upstream fix arrives only by a deliberate
  version bump, and replacing the container means replacing the database's
  home with it.

### Neutral

- A model key is still written to the environment file for OpenBot's own
  Bots; it is simply not required to boot.
- The heartbeat in the bridge and the 300 second watchdog are two guards on
  the same failure: a silent agent.
- The registered agent URL is a container-local name that only makes sense
  from inside the container that dials it, and it points at the bridge
  ([ADR-0002](0002-serial-agent-routing-chain.md),
  [ADR-0003](0003-bridge-peer-cidr-allowlist.md)).

## Alternatives considered

- **The source deployment** — too heavy for this hardware: it wants Bun, its
  own PostgreSQL and several more services than 2 cores and 8 GB can hold.
- **The `latest` tag** — a moving target under a pinned release, so a
  rebuild can change behavior with no commit to point at.
- **A separate worker container for the sweeps** — it would need the
  database URL, and in the embedded-PostgreSQL deployment that URL lives
  inside the server container.
