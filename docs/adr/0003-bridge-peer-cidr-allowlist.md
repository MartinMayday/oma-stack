# ADR-0003: The agent bridge admits only peers on a CIDR allowlist

- **Status:** accepted
- **Date:** 2026-11-11
- **Deciders:** MartinMayday (owner), Qoder (CTO/architecture)

## Context

The agent bridge binds `0.0.0.0:8765`. That is not a choice about
convenience: the OpenBot container reaches the host through the Docker
bridge gateway, and inside the container `127.0.0.1` is the container, so a
loopback-only bind would put the agent endpoints out of reach.

The same bind also puts the bridge on the LAN. Anything on the wifi could
then run the owner's agents and read their output: the agent runs as the
operator's own account, with that account's credentials and sessions.

Forwarded headers are not a usable substitute for a network boundary.
`X-Forwarded-For` is set by the client unless a trusted proxy overwrites it,
so anyone who can reach the port can claim any address they like.

The owner also wants the tailnet (see [ADR-0004](0004-tailscale-serve-never-funnel.md)),
where the owner's own devices live.

## Decision

Every request's peer address, taken from the socket and never from a header,
is checked against a CIDR list:

```
127.0.0.1/32, ::1/128, 172.16.0.0/12, 100.64.0.0/10
```

Anything else gets `403 {"error":"forbidden"}`.

- `127.0.0.1/32` and `::1/128` are the operator's own tools.
- `172.16.0.0/12` is the Docker bridge network, which is how the OpenBot
  container arrives.
- `100.64.0.0/10` is tailnet space, present because the tailnet publish is
  opt-in.
- The LAN range is deliberately absent, so a device on the wifi cannot run
  the owner's agents.

## Consequences

### Good

- A stranger on the LAN cannot drive the owner's agents, whatever they can
  reach.
- The check needs no secret, no rotation and no header the browser has to
  carry.
- The container path works without special cases, because the Docker bridge
  network is named in the list.
- The allowlist is one line, readable at a glance and easy to tighten.

### Bad

- The allowlist is a network boundary, not an identity: anything that can
  source from an allowed range is admitted, with no per-caller credential.
- A second Docker network outside `172.16/12`, or a different container
  runtime with its own range, is refused until the list is edited.
- The bridge still listens on every interface, so the port is visible on the
  LAN even though every request to it is refused.

### Neutral

- The tailnet entry only matters while the tailnet publish is on; without
  it the tailnet address is refused like any other.
- A refused request is logged with the peer address, so an unexpected
  caller is visible in the bridge log.
- This is the constraint that makes [ADR-0004](0004-tailscale-serve-never-funnel.md)
  publish the bridge over `tailscale serve` on port 9443 rather than on a
  raw port.

## Alternatives considered

- **An authentication header only** — a shared secret in a browser-facing
  header is weaker than a network boundary and is harder to rotate once it
  has leaked into a page, a log or a shell history.
- **Binding `127.0.0.1` only** — the OpenBot container could no longer
  reach the bridge, and the agent surface would lose its agents.
- **Trusting `X-Forwarded-For`** — trivially spoofed by anyone who can reach
  the port, which is exactly the party the check is meant to exclude.
