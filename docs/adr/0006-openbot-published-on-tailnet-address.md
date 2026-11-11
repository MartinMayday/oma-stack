# ADR-0006: OpenBot is published on the tailnet address, not its MagicDNS name

- **Status:** accepted
- **Date:** 2026-11-11
- **Deciders:** MartinMayday (owner), Qoder (CTO/architecture)

## Context

OpenBot in single-user mode (`OPENBOT_SINGLE_USER=true`, the kit's default)
admits every request as one administrator with no sign-in. Upstream therefore
refuses to start when `OPENBOT_PUBLIC_URL`, `OPENBOT_APP_URL` or
`TRUSTED_ORIGINS` names a public address. The classification is in
`server/src/config.ts`: `reachOf()` (L762) decides it, and
`singleUserAllowed()` (L629) enforces it.

`reachOf()` treats `100.64.0.0/10` as private, which produces a warning at
startup and no refusal. A `.ts.net` MagicDNS name is public: it has dots,
and it does not end in `.local`, `.internal`, `.lan` or `.home.arpa`. So the
name Tailscale gives the box is exactly the value OpenBot refuses.

The same split runs at request time. `singleUserRefusal`
(`server/src/request-trust.ts`) admits a request only when the Host it is
addressed to is loopback, one of the deployment's configured hosts, or an
address literal. A tailnet address qualifies as an address literal; a
`.ts.net` name does not.

That would leave OpenBot unreachable from the owner's phone unless it is
published some other way.

## Decision

OpenBot is published on the tailnet address in plain HTTP
(`http://100.x.y.z:3001`), implemented as
`components/openbot/docker-compose.override.yml` with that address, and that
origin is added to `TRUSTED_ORIGINS`.

The tailnet transport is WireGuard-encrypted, so the missing TLS is not a
loss of confidentiality on the wire. The certificate Serve issues for the
`.ts.net` name is not used for OpenBot.

Forgejo and the bridge stay published by `tailscale serve` on the MagicDNS
name ([ADR-0004](0004-tailscale-serve-never-funnel.md)), because neither has
this restriction. The single image and its published port come from
[ADR-0005](0005-one-openbot-image-upstream-corrections.md).

## Consequences

### Good

- OpenBot starts: the tailnet address is private to `reachOf()`, so the
  server only warns instead of refusing.
- The browser can talk to the API, because the published origin is in
  `TRUSTED_ORIGINS`.
- Nothing is exposed to the internet and no public certificate is needed.
- The override file is a separate artifact, so deleting it takes OpenBot off
  the tailnet without editing the compose file.

### Bad

- The OpenBot URL on a phone is an address rather than a pretty name, and it
  is not covered by the tailnet certificate.
- The address can change if the node is re-authenticated, and every device
  that bookmarked the old URL has to be corrected.

### Neutral

- `oma serve refresh` re-publishes OpenBot and re-points Forgejo's
  `ROOT_URL`, `DOMAIN` and `SSH_DOMAIN` in one step.
- OpenBot warns at every boot that it answers on an address beyond this
  machine, and that anybody on that network is the administrator. That
  warning is correct: on the tailnet, that is the owner's own devices.
- The bridge and Forgejo keep their HTTPS endpoints, so only OpenBot is
  addressed by number.

## Alternatives considered

- **The MagicDNS name** — OpenBot refuses to start when it is given a
  public address, and `reachOf()` classifies the name as public.
- **Turning off single-user mode** — that needs a real identity provider
  (Google, Microsoft or Okta OAuth), which is out of proportion for one
  person's laptop.
- **Serving OpenBot through `tailscale serve`** — the same public-name
  refusal applies twice over: the configured origin would be the public name,
  and at request time the Host a request is addressed to is checked against
  those configured addresses, which a `.ts.net` name does not match.
