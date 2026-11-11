# Fallback CI/Forge stack — command-level spec (MacBook Pro 2014 Intel / Arch x86_64, 2026-11-11)

> **Storage note (2026-11-11, package v1.1.0).** This spec was written before the
> storage tiering was decided. Its `/mnt/usb/forgejo/forgejo-repositories` and
> `host.workdir_parent: /mnt/sd/act-work` recommendations are **superseded**:
> the hot tier (DB, repositories, Actions logs/artifacts, mirror cache) now
> lives on the internal SSD, the USB SATA disk holds dated backups only, and
> the SD card is optional runner scratch with an automatic fallback. The
> config-key facts and the `ProtectSystem=strict` behaviour below still hold.
> See `docs/ARCHITECTURE.md` → "Storage layout" for the current layout.

## Topology
| Piece | Where | What it gives you while GitHub Actions is billing-locked |
|---|---|---|
| github.com/OWNER/REPO | GitHub | Canonical remote, issues, PRs, releases — unchanged, still canonical |
| Forgejo 17.0.1 (web) | MacBook, `127.0.0.1:3000` behind Caddy (public) or Tailscale (tailnet) | Second forge: pull-mirror of GitHub, own web UI/API, own issues+PRs |
| forgejo-runner 13.2.1 | MacBook (docker or `host` labels) | Independent CI executor; runs the mirrored workflows |
| runner cache server | MacBook, internal to the runner | Backs `ACTIONS_CACHE_URL` for `actions/cache` |
| GitHub self-hosted runner (optional probe) | Same MacBook | Tests whether a self-hosted runner still gets jobs under the lock |

The fallback provides (a) CI that runs your workflow YAML on your own box with no billing dependency, (b) a second pushable remote, (c) a periodic read-only issue snapshot. It does **not** provide GitHub PR/issue UI, branch protection (already unavailable on the locked account: "Upgrade to GitHub Pro or make this repository public to enable this feature."), GitHub-hosted runners, or GitHub Pages. Agents (Qoder, Z.ai GLM, MiniMax) run **locally** on the MacBook and are never invoked by CI.

## Forgejo on Arch
Package `forgejo` **17.0.1-1** in `extra`, depends on `git, glibc, sqlite` — https://archlinux.org/packages/extra/x86_64/forgejo/ , file list https://archlinux.org/packages/extra/x86_64/forgejo/files/ . Upstream LTS line is **15.0.11** (docs version switcher, https://forgejo.org/docs/). Pin one line; never mix server/runner majors. Packaged files (verified by unpacking `forgejo-17.0.1-1-x86_64.pkg.tar.zst`): `/usr/bin/forgejo`, `/etc/forgejo/app.ini` (0660 root:forgejo), `/usr/lib/systemd/system/forgejo.service`, `/usr/lib/sysusers.d/forgejo.conf` (`u! forgejo - "Forgejo daemon user" /var/lib/forgejo /bin/bash`), `/usr/lib/tmpfiles.d/forgejo.conf` (creates `/var/lib/forgejo{,/data,/data/forgejo-repositories,/data/attachments,/data/indexers,/data/tmp}`, `/var/lib/forgejo/custom`, `/var/log/forgejo`).

```bash
sudo pacman -Syu forgejo git sqlite
sudo install -d -o forgejo -g forgejo /var/lib/forgejo
sudo -u forgejo /usr/bin/forgejo generate secret SECRET_KEY      # -> [security] SECRET_KEY
sudo -u forgejo /usr/bin/forgejo generate secret INTERNAL_TOKEN  # -> [security] INTERNAL_TOKEN
sudo -u forgejo /usr/bin/forgejo --config /etc/forgejo/app.ini admin user create \
      --username ci-admin --password '<strong-pw>' --email ci-admin@example.invalid \
      --admin --must-change-password=false
sudo systemctl enable --now forgejo.service && systemctl status forgejo
```
`forgejo generate secret {SECRET_KEY,INTERNAL_TOKEN,JWT_SECRET,LFS_JWT_SECRET}` and `forgejo admin user create --username --password --email --admin --random-password --must-change-password --access-token` are documented at https://forgejo.org/docs/latest/admin/command-line/ . Run the CLI as user `forgejo` with the unit's `--config`/`--work-path`: the packaged unit sets `ProtectSystem=strict` and `PrivateUsers=true`. Minimal `app.ini` additions (key names verified against the packaged 17.0.1 `app.ini` and https://forgejo.org/docs/latest/admin/config-cheat-sheet/):

```ini
RUN_USER = forgejo
[server]
DOMAIN = git.example.com
ROOT_URL = https://git.example.com/
PROTOCOL = https
HTTP_ADDR = 127.0.0.1
HTTP_PORT = 3000
APP_DATA_PATH = /var/lib/forgejo/data
SSH_PORT = 2222
SSH_LISTEN_PORT = 2222
SSH_DOMAIN = git.example.com
START_SSH_SERVER = true
[database]
DB_TYPE = sqlite3
PATH = /var/lib/forgejo/data/forgejo.db
SQLITE_JOURNAL_MODE = WAL
[security]
SECRET_KEY = <from forgejo generate secret SECRET_KEY>
INTERNAL_TOKEN = <from forgejo generate secret INTERNAL_TOKEN>
[repository]
ROOT = /mnt/usb/forgejo/forgejo-repositories
[log]
MODE = file
LEVEL = Info
[service]
DISABLE_REGISTRATION = true
REQUIRE_SIGNIN_VIEW = true
[actions]
ENABLED = true
DEFAULT_ACTIONS_URL = https://code.forgejo.org
[mirror]
ENABLED = true
```
`ROOT_URL` must match the public URL or generated links break (https://forgejo.org/docs/latest/admin/setup/reverse-proxy/). `SSH_PORT` is the port shown in clone URLs; `SSH_LISTEN_PORT` is what the built-in server binds (default `%(SSH_PORT)s`). `START_SSH_SERVER` = Forgejo's built-in SSH server (default `false`); `SSH_CREATE_AUTHORIZED_KEYS_FILE = true` (default) lets system `sshd` serve git via `AuthorizedKeysCommand`. Packaged unit `/usr/lib/systemd/system/forgejo.service` (verbatim essentials):
```ini
[Unit]
Description=Forgejo
After=network.target
[Service]
User=forgejo
Group=forgejo
Type=simple
WorkingDirectory=~
RuntimeDirectory=forgejo
LogsDirectory=forgejo
StateDirectory=forgejo
ExecStart=/usr/bin/forgejo web -c /etc/forgejo/app.ini
Restart=always
RestartSec=2s
ReadWritePaths=/etc/forgejo/app.ini
ProtectSystem=strict
ProtectHome=true
PrivateUsers=true
PrivateTmp=true
NoNewPrivileges=True
[Install]
WantedBy=multi-user.target
```
The upstream generic unit (User=git, `ExecStart=/usr/local/bin/forgejo web --config /etc/forgejo/app.ini`, https://code.forgejo.org/forgejo/forgejo/raw/branch/forgejo/contrib/systemd/forgejo.service) is **not** the Arch one — use the packaged unit. To move data onto the USB disk add `RequiresMountsFor=/mnt/usb` and `ReadWritePaths=/mnt/usb /mnt/usb/forgejo`, otherwise ProtectSystem=strict blocks the write.

## Network access
Caddy (simplest; Caddy obtains/renews certs itself) — https://forgejo.org/docs/latest/admin/setup/reverse-proxy/ , file `/etc/caddy/Caddyfile`:
```
git.example.com {
  reverse_proxy 127.0.0.1:3000
}
```
Caddy proxies WebSockets transparently, so the Actions log stream needs no extra headers. nginx alternative (official block; `Upgrade`/`Connection` are the WebSocket part):
```nginx
server {
    listen 80; listen [::]:80;
    server_name git.example.com;
    merge_slashes off;                       # required for URL-encoded slashes
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Connection $http_connection;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        client_max_body_size 512M;
    }
}
```
SSH, two models. *Shared port 22*: system `sshd` stays on 22, `START_SSH_SERVER = false`, `SSH_CREATE_AUTHORIZED_KEYS_FILE = true`; add to `/etc/ssh/sshd_config`: `AuthorizedKeysCommand /usr/bin/forgejo --config=/etc/forgejo/app.ini serv key-%i`; clone URL `git@git.example.com:OWNER/REPO.git`. *Separate port (recommended here)*: `START_SSH_SERVER = true`, `SSH_PORT = 2222`, `SSH_LISTEN_PORT = 2222`, `SSH_DOMAIN = git.example.com` → clone URL `ssh://git@git.example.com:2222/OWNER/REPO.git`; no root, no conflict with system sshd (public 2222 needs a firewall rule). Tailscale (recommended if the laptop is off a trusted LAN): `sudo tailscale up` then `tailscale serve --bg --https=443 127.0.0.1:3000` (current CLI: `tailscale serve [flags] <target>`, `--https=<port>`/`--http=<port>`, `--bg`; "only http://127.0.0.1 is supported for proxies" — https://tailscale.com/docs/reference/tailscale-cli/serve). Access via the MagicDNS name; `tailscale funnel` = public, avoid. Match `ROOT_URL` to the served URL.

## Forgejo Actions runner
Binary **forgejo-runner v13.2.1**, hosted on code.forgejo.org (not codeberg): `https://code.forgejo.org/forgejo/runner/releases/download/v13.2.1/forgejo-runner-13.2.1-linux-amd64` (+ `.asc`, `.sha256`). Latest-version discovery (official install doc): `curl -s https://data.forgejo.org/api/v1/repos/forgejo/runner/releases/latest | jq -r .name` → `v13.2.1`. Docs: https://forgejo.org/docs/latest/admin/actions/installation/binary/ .
```bash
sudo install -o root -g root -m 0755 forgejo-runner-13.2.1-linux-amd64 /usr/local/bin/forgejo-runner
sudo useradd --create-home --shell /bin/bash runner
sudo usermod -aG docker runner          # only for docker labels
sudo -u runner /usr/local/bin/forgejo-runner generate-config > /home/runner/runner-config.yml
chown runner:runner /home/runner/runner-config.yml
```
There is **no default config path**; `-c` is mandatory. Registration = `server.connections.<name>.{url,uuid,token}` (https://forgejo.org/docs/latest/admin/actions/registration/):
```yaml
server:
  connections:
    forgejo:
      url: https://git.example.com/
      uuid: <uuid from Forgejo UI>
      token: <token from Forgejo UI>
runner:
  file: .runner
  capacity: 1
  labels:
    - self-hosted:host
    - ubuntu-latest:docker://ghcr.io/catthehacker/ubuntu:act-22.04
host:
  workdir_parent: /mnt/sd/act-work
cache:
  enabled: true
  port: 0
  dir: /var/cache/forgejo-runner
```
Token sources: UI at `/admin/actions/runners` (system), `/org/{org}/settings/actions/runners`, `/user/settings/actions/runners`, `/{owner}/{repo}/settings/actions/runners` → shows UUID + token. Offline/scripted: `sudo -u forgejo /usr/bin/forgejo forgejo-cli actions register --name runner-name --scope <org> --secret <40-hex>` returns the UUID; that 40-hex secret is the token. `forgejo forgejo-cli actions generate-runner-token` / `... generate-secret` also exist; `forgejo-runner register` is **deprecated**; ephemeral mode = `--ephemeral` on `forgejo forgejo-cli actions register`. Unit (`https://code.forgejo.org/forgejo/runner/raw/branch/main/contrib/forgejo-runner.service` → `/etc/systemd/system/forgejo-runner.service`): `After=docker.service`, `ExecStart=/usr/local/bin/forgejo-runner daemon -c /home/runner/runner-config.yml`, `ExecReload=/bin/kill -s HUP $MAINPID`, `User=runner`, `WorkingDirectory=/home/runner`, `Restart=on-failure`, `TimeoutStopSec=infinity`, `RestartSec=10`. Maturity (2026): **not** a drop-in for GitHub Actions — "designed to be familiar … but not designed to be compatible" (https://forgejo.org/docs/latest/user/actions/github-actions/). Confirmed from docs + source:
* Workflow discovery order `.forgejo/workflows` → `.gitea/workflows` → `.github/workflows`, **first existing directory wins** (forgejo v17 `modules/actions/workflows.go`: `workflowSources := []string{".forgejo/workflows",".gitea/workflows",".github/workflows"}`; `IsWorkflow` accepts all three prefixes) — `.forgejo/workflows` *shadows* `.github/workflows`, it is not merged.
* `matrix` supported (vendored `act/model/workflow.go`: `RawMatrix`, `Strategy.GetMatrixes()` cross product; `act/jobparser` evaluates it). `services:` supported (`Services map[string]*ContainerSpec`). `jobs.<id>.container` supported and overrides the label image.
* `actions/cache` supported via the runner's internal cache server (`cache.enabled: true` → `ACTIONS_CACHE_URL`; use `https://data.forgejo.org/actions/cache`). `self-hosted` supported as label type `host` (`self-hosted:host` = no isolation, "a single job can permanently destroy the host").
* Documented differences: default image is Debian bookworm + node only (not ubuntu); some `github` context keys missing; `job.permissions` and `continue-on-error` **ignored**; OIDC uses `enable-openid-connect` instead of `permissions: id-token: write`. Third-party marketplace actions may fail.

## GitHub self-hosted runner
Install (latest v2.338.2): `https://github.com/actions/runner/releases/download/v2.338.2/actions-runner-linux-x64-2.338.2.tar.gz` → unpack to `/opt/actions-runner`, `sudo ./bin/installdependencies.sh`, then:
```bash
cd /opt/actions-runner
./config.sh --unattended --url https://github.com/OWNER/REPO \
            --token <REGISTRATION_TOKEN> --name macbook-ci --labels macbook,self-hosted \
            --runnergroup <group> --work /mnt/sd/actions-runner-work
sudo ./svc.sh install runner && sudo ./svc.sh start
```
Flags confirmed from `src/Runner.Listener/Runner.cs` (v2.338.2): `--unattended --url --token --name --runnergroup --labels --no-default-labels --local --work --replace --pat --disableupdate --ephemeral`. Default labels `self-hosted,linux,X64`. Token source: `POST https://api.github.com/repos/OWNER/REPO/actions/runners/registration-token` (org: `POST /orgs/ORG/actions/runners/registration-token`) — classic PAT needs `repo` scope for a private repo, `admin:org` for the org endpoint; fine-grained PAT needs "Administration: read/write" (https://docs.github.com/en/rest/actions/self-hosted-runners#create-a-registration-token-for-a-repository). Tokens are short-lived (~1 h) → mint at provisioning time. **Billing — CONFIRMED (pricing):** "The following usage remains free independently and does not reduce the included compute usage: Standard GitHub-hosted runners in public repositories. … **Self-hosted runners.**" (https://docs.github.com/en/billing/concepts/product-billing/github-actions) — self-hosted compute never draws on included compute, so it cannot be exhausted. **Billing — INFERRED (does a self-hosted job still start under the lock?):** not documented by GitHub. For: https://github.com/orgs/community/discussions/210453 (2026-10-16) "**Self-hosted runners on the same account work fine** — only GitHub-hosted jobs are refused."; https://github.com/orgs/community/discussions/208297 (2026-09-19) confirms the lock blocks even public-repo GitHub-hosted jobs. Against: https://docs.github.com/en/billing/how-tos/troubleshooting/locked-account — a failed authorization hold "can also lock your personal account billing and block GitHub Actions **or other free-tier access**" (free-tier paths are not promised to survive). **Verdict: probably works, not guaranteed — UNCERTAIN, test empirically before designing around it.** Test (≈30 min): register the runner against one private and one public repo; push a workflow with `runs-on: [self-hosted, macbook]`; `gh api repos/OWNER/REPO/actions/runners` (expect `"status":"online"`); `gh run list` (expect a run that actually starts). `online` but no dispatch ⇒ the lock blocks private-repo dispatch → Forgejo-only CI. Private-repo dispatch to a self-hosted runner is likewise **INFERRED/undocumented**.

## Mirroring
Pull mirror = Forgejo pulls from GitHub; push mirror = Forgejo pushes to GitHub (https://forgejo.org/docs/latest/user/repo-mirror/). Pull mirror (GitHub → Forgejo) can **only be set at repo creation**: "You can only set up pull mirroring for repositories that don't exist yet on your instance. Once the repository is created, you can't convert it into a pull mirror anymore." UI: Create… → New Migration → service GitHub → check "This repository will be a mirror". API:
```bash
curl -X POST https://git.example.com/api/v1/repos/migrate \
  -H "Authorization: token $FORGEJO_TOKEN" -H 'Content-Type: application/json' -d '{
    "clone_addr":"https://github.com/OWNER/REPO.git",
    "repo_name":"REPO","service":"github",
    "auth_username":"<github-user>","auth_token":"<github-PAT>",
    "mirror":true,"mirror_interval":"10m",
    "issues":true,"labels":true,"milestones":true,"pull_requests":true,"releases":true,"wiki":false,
    "private":true,"uid":<admin-uid>,"repo_owner":"<forgejo-user>",
    "description":"read-only mirror of github.com/OWNER/REPO"}'
```
`MigrateRepoOptions` (Forgejo v17 OpenAPI): required `clone_addr`, `repo_name`; optional `service` (enum `git|github|gitea|gitlab|gogs|onedev|gitbucket|codebase|forgejo|pagure|bitbucketdc`), `auth_username`, `auth_token`, `mirror`, `mirror_interval`, `issues`, `labels`, `milestones`, `pull_requests`, `releases`, `wiki`, `lfs`, `private`, `repo_owner`, `uid`, `description`, `lfs_endpoint`. `uid` = numeric admin id from `GET /api/v1/admin/users`. A GitHub PAT with `repo` scope is needed for private repos; `issues:true` imports issues **at migration time only**. Push mirror (Forgejo → GitHub) is **destructive**: "This will force push to the remote repository. This will overwrite any changes in the remote repository!" and "Forgejo will use `git push --mirror` when there is no Branch Filter specified."
```bash
curl -X POST https://git.example.com/api/v1/repos/FORGEJO_OWNER/REPO/push_mirrors \
  -H "Authorization: token $FORGEJO_TOKEN" -H 'Content-Type: application/json' -d '{
    "remote_address":"https://github.com/OWNER/REPO.git",
    "remote_username":"<gh-user>","remote_password":"<gh-PAT>",
    "branch_filter":"main,feat/*","interval":"10m","sync_on_commit":true,"use_ssh":false}'
```
`CreatePushMirrorOption` (OpenAPI): `remote_address`, `remote_username`, `remote_password`, `interval`, `branch_filter`, `sync_on_commit`, `use_ssh`. Manual sync `POST /api/v1/repos/{owner}/{repo}/push_mirrors-sync`; pull-mirror sync `POST /api/v1/repos/{owner}/{repo}/mirror-sync`. SSH auth: `use_ssh:true` + `git@host:owner/repo.git`, leave username/password empty; Forgejo generates an Ed25519 key — add its public key as a deploy key on the target. LFS objects are not mirrored over SSH. **Recommended direction: GitHub → Forgejo only.** The pull mirror is non-destructive; a Forgejo→GitHub push mirror must carry an explicit branch filter, because `git push --mirror` from a Forgejo repo lacking a GitHub branch *deletes* it. Git-level one-directional sync (GitHub → Forgejo), if you want a tighter cadence than the built-in cron (`[cron.update_mirrors] SCHEDULE = @every 10m`, `PULL_LIMIT/PUSH_LIMIT = 50`):
```bash
git clone --bare https://github.com/OWNER/REPO.git /srv/mirror/REPO.git
git -C /srv/mirror/REPO.git remote add forgejo https://git.example.com/FORGEJO_OWNER/REPO.git
git -C /srv/mirror/REPO.git push forgejo 'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*'
```
Never `git push --mirror` here (it pushes refs/remotes/* and deletes Forgejo-side branches absent from GitHub). Drive it from a systemd timer (`OnCalendar=*:0/15`, `Persistent=true`); credential the Forgejo remote with a scoped token or SSH deploy key. GitHub issues are not synced continuously. Keep GitHub as the tracker and export a read-only snapshot into a Forgejo repo:
```bash
gh issue list --repo OWNER/REPO --state all --limit 1000 \
  --json number,title,state,labels,createdAt,closedAt,url > issues.json
git -C /srv/issue-export add issues.json && git -C /srv/issue-export commit -m 'chore(sync): issue snapshot'
```
(`gh issue list` flags verified from the gh manual; raw equivalent `gh api repos/OWNER/REPO/issues?state=all`.)

## Storage layout
| Device | Content | Why |
|---|---|---|
| 128 GB internal SSD (boot) | OS, `/var/lib/forgejo` (SQLite DB + app data + logs), `/var/cache/forgejo-runner`, Docker images | SQLite/log writes are constant small writes; WAL (`SQLITE_JOURNAL_MODE = WAL`, default) rewrites the WAL continuously |
| 512 GB SD card | **scratch only**: `host.workdir_parent`, action-cache scratch. No SQLite, no `APP_DATA_PATH` | Consumer SD cards have no wear-levelling guarantee and a far lower write-endurance budget than SSD/NVMe (engineering guidance — no citable standard — but the risk is real) |
| 4 TB USB SATA | `[repository] ROOT = /mnt/usb/forgejo/forgejo-repositories` (+ optional `[storage.actions_log]` / `[storage.actions_artifacts]` PATH) | Repos are large and append-mostly; cheap bulk storage |

Never put the Forgejo database on the SD card. On the USB disk it is only safe with a stable mount: UUID-based fstab entry plus `RequiresMountsFor=/mnt/usb` **and** `ReadWritePaths=/mnt/usb/forgejo` in `forgejo.service` (systemd.unit(5): "Automatically adds dependencies of type Requires= and After= for all mount units required to access the specified path"), else Forgejo starts on an unmounted `/mnt/usb` and writes into the root fs. Per-subsystem storage keys (https://forgejo.org/docs/latest/admin/setup/storage/): `[storage] PATH` for all subsystems, or `[attachment]`, `[lfs]`, `[avatar]`, `[repo-avatar]`, `[repo-archive]`, `[packages]`, `[storage.actions_log]`, `[storage.actions_artifacts]` individually. Actions logs are server-side too (`[actions] LOG_RETENTION_DAYS = 365`, `ARTIFACT_RETENTION_DAYS = 90`, `LOG_COMPRESSION = zstd`) — drop retention to ~30 days on a 128 GB SSD.

## Omarchy on Intel
**CONFIRMED — Intel is supported.** https://omarchy.org/manual/mac-support/ : "Omarchy has built-in support for **Intel Macs**." and "installing on an M-series Mac is not directly supported at this time." The installer "detects Mac hardware and applies the needed fixes automatically: Broadcom Wi-Fi drivers and firmware, the SPI keyboard driver on the MacBook models that need it, and an NVMe suspend fix for those same models." The page's T1/T2 special-casing covers 2016 Touch Bar and 2018+ models — a 2014 MacBook has neither chip and takes the plain Intel path. Blockers (same page): "Omarchy only supports being the **only** OS installed at the moment. During the installation, the drive will be wiped and MacOS will no longer be bootable." Secure Boot must be disabled (Startup Security Utility → "No Security" + allow external media). Recommendation: **plain Arch Linux x86_64**, not Omarchy, for a CI box — Omarchy is a desktop image (Hyprland + Quickshell), it wipes the 128 GB boot SSD, and adds no CI value. Use Omarchy only if the box is meant to be a Hyprland workstation. (Judgement call, not a documented limitation.) Hardware reality (2014 dual-core i5 / 8 GB):
* CPU: 2 cores/4 threads → `runner.capacity: 1`, slow Docker builds; `runner.timeout` default 3h.
* RAM: 8 GB shared with the desktop → cap Docker (`/etc/docker/daemon.json` `"memory": 4g`), keep capacity 1, prefer `docker` labels over `host`.
* Storage: 128 GB SSD is the ceiling for Docker images + Forgejo DB; move Docker `data-root` to the USB disk if it is USB3.
* Always-on: `systemd-inhibit --what=sleep:idle --mode=block --who=ci --why="CI runner"` (systemd-inhibit(1) default `idle:sleep:shutdown`) plus `/etc/systemd/logind.conf`: `HandleLidSwitch=ignore`, `IdleAction=ignore`; run the inhibitor as a unit. Omarchy's own sleep switches: `/etc/systemd/sleep.conf.d/omarchy-sleep-disabled.conf`, `omarchy toggle suspend` (https://omarchy.org/manual/system-sleep/).
* Graphics: Broadwell iGPU (HD Graphics 5000 / Iris Pro 6100-6500) → Mesa + `i915`; the 2014 15" also has an NVIDIA GT 750M needing the 470 legacy driver — if the display misbehaves, boot `nomodeset`. (ArchWiki pages were unreachable from here — Anubis bot wall — so treat driver detail as **UNCERTAIN**; safe path is headless/SSH-only.)
* Local LLM inference: CPU-only — no CUDA, no ROCm on Broadwell; Vulkan only via Mesa llvmpipe/lavapipe. Acceptable: the LLMs run locally, not in CI, so the runner needs no GPU.

## Open questions / risks
1. **Does a self-hosted GitHub runner still get jobs under the billing lock? UNCERTAIN.** Pricing for self-hosted runners is CONFIRMED free; continued dispatch under a lock is only community-reported. Run the empirical test in the GitHub section before designing around it. `online` but no dispatch ⇒ Forgejo-only CI.
2. **Private-repo dispatch to self-hosted runners: INFERRED, undocumented.** Also: branch protection / required status checks on private repos are unavailable on a Free-plan locked account, so even a working self-hosted runner cannot gate merges as the runbook expects.
3. **Forgejo Actions is "familiar, not compatible".** Expect a parallel `.forgejo/workflows/` copy (it *shadows* `.github/workflows`, first dir wins). `permissions:`/`continue-on-error:` ignored; `services:`/`matrix:`/`container:` work.
4. **Private mirrors need a GitHub PAT** — scoped `repo` (read), rotated, stored in the Forgejo admin UI, never in the repo.
5. **One-directional mirroring on purpose.** Any Forgejo→GitHub push needs an explicit branch filter; `git push --mirror` deletes GitHub branches.
6. **Hardware ceiling.** 2 cores / 8 GB / 128 GB SSD ⇒ capacity 1, small images, `--privileged` off. If build times are untenable, fall back to a cheap x86-64 VPS running the same Forgejo + runner pair, with this MacBook as editor/agent host.
7. **SD card = scratch only.** Never the DB. USB disk needs `RequiresMountsFor=` + `ReadWritePaths=` (packaged unit is `ProtectSystem=strict`).
8. **Exposure.** Keep Forgejo on the tailnet or behind Caddy+TLS; `DISABLE_REGISTRATION = true`, `REQUIRE_SIGNIN_VIEW = true`, SSH keys only, disable basic auth if fronted by an authenticating proxy.
9. **Not verifiable from here:** ArchWiki Forgejo / Intel-graphics / SD-card pages and gitlab.archlinux.org packaging sources sit behind an Anubis bot wall; the Arch package facts above come from archlinux.org's package DB and from unpacking the published `.pkg.tar.zst`, which is authoritative for paths, unit, user and file list.
