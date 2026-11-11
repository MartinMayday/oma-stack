#!/usr/bin/env bash
# 30-github-runner.sh — register the MacBook as a GitHub self-hosted runner.
#
# WHY THIS EXISTS
#   On 2026-11-11 the account MartinMayday was found to be billing-locked.
#   GitHub then refuses to start ANY hosted job. Measured facts:
#     - public repo, runs-on: ubuntu-latest  -> job fails (billing lock)
#     - public repo, runs-on: [self-hosted,linux,x64] -> job QUEUES, waits
#       for a runner. The lock does NOT block self-hosted dispatch.
#     - private repo, ANY runs-on -> workflow never registers (startup_failure,
#       zero jobs). No runner type helps there.
#
#   So: registering this MacBook as a self-hosted runner keeps GitHub CI alive
#   for PUBLIC repos. Private repos must live in Forgejo instead.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/_lib.sh"
source "${HOST_ENV}"

need_root "$@"

if [[ "${ENABLE_GITHUB_RUNNER}" != "1" ]]; then
  log "ENABLE_GITHUB_RUNNER=0 — skipping the GitHub runner"
  exit 0
fi

RUNNER_VERSION="${GH_RUNNER_VERSION:-2.338.2}"

# ---------------------------------------------------------------------------
# 1. Binary
# ---------------------------------------------------------------------------
log "installing the GitHub Actions runner ${RUNNER_VERSION}"
if [[ -x "${GITHUB_RUNNER_DIR}/bin/Runner.Listener" ]]; then
  ok "already installed at ${GITHUB_RUNNER_DIR}"
else
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/gh-runner.tar.gz" \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
    || die "runner download failed"
  if curl -fsSL -o "$tmp/gh-runner.sha256" \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz.sha256" 2>/dev/null; then
    expected=$(cut -d' ' -f1 <"$tmp/gh-runner.sha256")
    actual=$(sha256sum "$tmp/gh-runner.tar.gz" | cut -d' ' -f1)
    [[ "$expected" == "$actual" ]] && ok "sha256 verified" \
      || { rm -rf "$tmp"; die "sha256 mismatch — refusing to install"; }
  else
    warn "no published sha256; installing unverified"
  fi
  mkdir -p "$GITHUB_RUNNER_DIR"
  tar -xzf "$tmp/gh-runner.tar.gz" -C "$GITHUB_RUNNER_DIR"
  rm -rf "$tmp"
  "${GITHUB_RUNNER_DIR}/bin/installdependencies.sh" || warn "installdependencies failed (non-fatal on Arch)"
  ok "runner unpacked at ${GITHUB_RUNNER_DIR}"
fi

# ---------------------------------------------------------------------------
# 2. Registration token
# ---------------------------------------------------------------------------
# Registration tokens live ~1 hour, so mint one now.
# The account-level endpoint registers the runner for ALL repos owned by the
# user, which is what we want (one machine, many repos).
log "minting a registration token"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
if [[ -z "$GITHUB_TOKEN" && -f "$GITHUB_TOKEN_FILE" ]]; then
  GITHUB_TOKEN=$(cat "$GITHUB_TOKEN_FILE")
fi
if [[ -z "$GITHUB_TOKEN" ]] && have gh; then
  GITHUB_TOKEN=$(gh auth token 2>/dev/null || true)
fi
[[ -n "$GITHUB_TOKEN" ]] || die "no GitHub token available.
  Put a PAT with 'repo' scope in ${GITHUB_TOKEN_FILE} (mode 0600), or export
  GITHUB_TOKEN=ghp_... and re-run."

REG=$(curl -fsS -X POST \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/users/${GITHUB_USER}/actions/runners/registration-token" 2>&1) \
  || { echo "$REG"; die "registration token request failed"; }

REG_TOKEN=$(printf '%s' "$REG" | jq -r '.token // empty')
[[ -n "$REG_TOKEN" ]] || { echo "$REG"; die "no token in the response (scope 'repo' required)"; }
ok "registration token acquired"

# ---------------------------------------------------------------------------
# 3. Configure
# ---------------------------------------------------------------------------
log "configuring the runner"
if [[ -f "${GITHUB_RUNNER_DIR}/.runner" ]]; then
  ok "runner already configured — skipping"
else
  cd "$GITHUB_RUNNER_DIR"
  ./config.sh --unattended \
    --url "https://github.com/${GITHUB_USER}" \
    --token "$REG_TOKEN" \
    --name "${GITHUB_RUNNER_NAME}" \
    --labels "${GITHUB_RUNNER_LABELS}" \
    --work "$(runner_workdir)/gh-runner" \
    --replace
  ok "runner configured"
fi

# ---------------------------------------------------------------------------
# 4. Service
# ---------------------------------------------------------------------------
log "installing the service"
cd "$GITHUB_RUNNER_DIR"
./svc.sh install "${GITHUB_RUNNER_NAME}" || warn "svc.sh install failed"
./svc.sh start        "${GITHUB_RUNNER_NAME}" || warn "svc.sh start failed"
sleep 4
ok "GitHub runner service installed and started"

# ---------------------------------------------------------------------------
# 5. Verify it shows up online
# ---------------------------------------------------------------------------
log "verifying registration"
curl -fsS -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/users/${GITHUB_USER}/actions/runners" \
  | jq -r '.runners[]? | "\(.name)\t\(.status)\t\(.labels|map(.name)|join(","))"' \
  | sed 's/^/  /' || warn "could not list runners"

cat <<EOF

  The MacBook is now a GitHub self-hosted runner for all repos owned by
  ${GITHUB_USER}. Public-repo workflows with 'runs-on: [self-hosted,linux,x64]'
  will run here even while the account is billing-locked.

  Private repos are still blocked by GitHub (the workflow never registers).
  Those live in Forgejo — see mirror/ and the RUNBOOK.
EOF
