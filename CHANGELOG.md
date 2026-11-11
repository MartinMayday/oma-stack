# Changelog

All notable changes to `oma-stack` are recorded in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-11-11

The tailnet release. The stack stops being "localhost only" and becomes
reachable from the five devices you actually carry, without opening a single
port to the internet.

### Added

- **The `oma` CLI** (`bin/oma`). One command for the whole stack: `oma status`,
  `oma doctor`, `oma open`, `oma logs <unit>`, `oma agent list`,
  `oma agent test <name>`, `oma handoff ls|put|watch`, `oma serve show|refresh`,
  `oma update`, `oma uninstall`. It reads. It never merges, deploys, or touches
  a credential.
- **The landing page** (`site/index.html`). The same product, in the same
  palette as the CLI: ink, panel, ember, ice, jade.
- **The tailnet component** (`components/tailscale/`). `tailscaled` plus
  `tailscale serve`, the per-device story for the iPhone, the iPad, the Mac
  Studio and the Proxmox node, and `tailnet-policy.json` — the access-policy
  template that turns the tailnet from allow-all into deny-by-default.
- **The agent routing chain.** The registry carries an ordered chain; if the
  default agent fails the next one takes over, and the reply says which agent
  actually answered.
- **The bridge IP allowlist.** The bridge accepts callers only from the
  networks in `AGENT_BRIDGE_ALLOWED_IPS`, and everything else is refused.
- **The OpenBot scheduled worker** (`components/openbot/openbot-worker.sh`).
  The all-in-one image carries no scheduler, so the kit runs the two sweeps
  upstream expects from the outside: the routines sweep, which fires the
  routines that are due, and the staged-attachment sweep, which culls blobs
  that were uploaded but never sent.

### Fixed

- **The credential directory is traversable.** It is created mode 0711, so the
  bridge can reach and read its own registry inside it while every file in it
  stays 0600.
- **The OpenBot computer policy denied a tool name upstream does not have.**
  Upstream's shell tool is `computer_run_command` and its own idiom for "a
  shell command is running" is the `intent` attribute, so the deny rule now
  keys off `intent == "run_command"`.
- **The OpenBot image is pinned.** `ghcr.io/copilotkit/openbot:v1.0.2`, not
  `latest`, so a redeploy cannot silently change the version underneath you.
- **`/workspace` and `/profiles` are volumes.** Bot files and the signed-in
  browser sessions now survive a redeploy instead of being deleted with the
  container.
- **Slow agents are no longer cut off.** The stall watchdog is raised to
  `OPENBOT_STALL_TIMEOUT_MS=300000`, and the bridge sends a heartbeat every
  `AGENT_BRIDGE_HEARTBEAT_SECONDS=15` while the CLI is silent.
- **`tailscale serve` runs with `--bg`.** Without it the command runs in the
  foreground and never returns, so the serve unit never completed.
- **Forgejo binds loopback only.** `FORGEJO_BIND=127.0.0.1`. The tailnet
  publishes it; nothing else can reach it.

### Changed

- **`EXPOSE_MODE` was reworked.** It was `none` (LAN only), `tailscale` or
  `caddy`, and the default put Forgejo on every interface. It is now
  `tailnet` (the default: loopback, published on the tailnet), `none` (this
  box only), `lan` (the explicit opt-in for LAN reachability) or `caddy`
  (public). The default install no longer answers on the LAN.
- **The `qoder` registry entry carries the repo-proven command**
  `qoder -p --no-session-persistence "<prompt>"`, taken from the agent-library
  receipts rather than from guesswork.

## [1.0.0] - 2026-11-11

The first release. A working CI box on a machine whose GitHub account cannot
start a single hosted job.

### Added

- **Forgejo**, with the tracker, the mirror and the CI server, on the internal
  SSD.
- **The runners**: `forgejo-runner` for your own pipelines, and a GitHub
  self-hosted runner so public repositories keep their CI alive while the
  account is billing-locked.
- **The mirror**: GitHub to Forgejo, one way, every fifteen minutes. Issues
  snapshotted read-only every thirty.
- **OpenBot**, the CopilotKit agent surface, in one container with its own
  database.
- **The agent bridge**: AG-UI over SSE, the agent registry, and the handoff
  queue with its audit log.
- **Storage tiering**: the internal SSD holds everything hot, the 4 TB USB SATA
  disk holds dated backups and nothing else, the SD card is optional runner
  scratch.
- **Backup to the USB disk**, every six hours, seven snapshots kept.
- **The healthcheck** (`verify/healthcheck.sh`): one PASS/WARN/FAIL report for
  the whole stack.
- **The runbook** (`docs/RUNBOOK.md`): what to do when something is broken.

[Unreleased]: https://github.com/MartinMayday/oma-stack/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/MartinMayday/oma-stack/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/MartinMayday/oma-stack/releases/tag/v1.0.0
