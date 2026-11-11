# Security

`oma-stack` is infrastructure for one person. One operator, one machine, one
private tailnet. There is no multi-tenant story here and no anonymous user.

The posture is simple to state: **nothing is published to the public
internet.** There is no router port forward, no public certificate, and no
`tailscale funnel`. The tailnet is how your other devices reach the box, and
the tailnet is yours.

## Supported versions

| Version | Supported |
|---|---|
| 1.1.x | yes |
| 1.0.x | no — upgrade to 1.1.x |
| < 1.0 | no |

Security fixes land in the current minor line only. `oma update` pulls the
newest kit and reinstalls it.

## Reporting a vulnerability

**Open a private advisory.** Use the GitHub Security Advisory form on
`MartinMayday/oma-stack` — "Security" tab, "Report a vulnerability" — rather
than a public issue. A public issue puts the details in front of everyone
before there is a fix.

You can also email the maintainer at the address listed on the GitHub profile
for `MartinMayday`, if you would rather not use the advisory form.

Please include:

- what an attacker can reach, and what they need in order to do it
- the version (`oma version`) and the host (`uname -a`, `cat /etc/os-release`)
- how to reproduce it
- whether it needs anything you set up yourself, such as a changed
  `EXPOSE_MODE` or an extra entry in the bridge allowlist

You will get an acknowledgement. If the report is accepted, a fix and a new
patch release follow, and the advisory is published once the fix is out.

## In scope

- An unauthenticated path to run an agent, read a secret, or reach a service
  that is supposed to be private.
- Anything that puts the stack on the public internet without being asked to.
- The bridge merging, deploying, opening a pull request, or changing a
  credential.
- The mirror writing anything back to GitHub.
- A secret readable by another user on the host.
- The computer policy failing to deny a destructive shell command.

## Out of scope

- **A compromised tailnet account.** If a device of yours is already in the
  tailnet, the tailnet is already inside the trust boundary. Revoke that
  device first.
- **A compromised host.** Root on the MacBook owns everything the kit does.
- **The GitHub billing lock.** It is upstream's problem, and the kit does not
  and cannot fix it.
- **Upstream defects.** Weaknesses in OpenBot, Forgejo, Tailscale, or the
  agent CLIs themselves belong upstream. Report them there.
- **Denial of service against your own machine.** It is a laptop with two
  cores.

## The defaults that matter

| Default | Where | What it does |
|---|---|---|
| Bridge IP allowlist | `AGENT_BRIDGE_ALLOWED_IPS` in `/etc/oma-stack/host.env` | The bridge answers only callers inside `127.0.0.1/32`, `::1/128`, `172.16.0.0/12` and `100.64.0.0/10`. Everything else is refused. |
| OpenBot single-user mode | `OPENBOT_SINGLE_USER=true` | Anyone who can reach port 3001 is an administrator. That is why it is not exposed to the LAN. The tailnet publishes it on the tailnet address, and the tailnet is yours. |
| Forgejo on loopback | `FORGEJO_BIND=127.0.0.1` and `EXPOSE_MODE=tailnet` | The tailnet publishes it. `EXPOSE_MODE=lan` is the one mode that puts it on your LAN, and it is not the default; `caddy` is the only mode that puts it on the public internet, and it is off by default. |
| Pinned image | `OPENBOT_IMAGE=ghcr.io/copilotkit/openbot:v1.0.2` | A redeploy cannot silently pull a different OpenBot underneath you. |
| Computer policy | `AGENT_COMPUTER_POLICY` in `/etc/oma-stack/openbot.env` | Mode `enforce`. The deny rule keys off `intent == "run_command"` and refuses `rm -rf /`, `rm -fr /`, `mkfs`, `dd if=` and the fork bomb. |
| Secret files at 0600 | `/etc/oma-stack/openbot.env`, `github.token`, `forgejo.token`, `agents.json` | The operator can read them and nobody else can. The directory itself is 0711, so the bridge can reach its own registry inside it without the directory being writable. |
| The bridge never merges | `components/agents/bridge.py` | It runs an agent and writes an answer to the outbox. It never merges, deploys, opens a pull request, or reads and writes a credential. |

## First thing to run

```bash
oma doctor
```

It reports the health of the whole stack, the agent keys, the agents the
bridge can run, and the state of the tailnet. If something looks wrong, this
is where to start, and [docs/RUNBOOK.md](docs/RUNBOOK.md) says what to do
about it.
