#!/usr/bin/env bash
# verify/billing-check.sh — what exactly does GitHub think of this account?
#
# The account MartinMayday is billing-locked: GitHub refuses to start any
# hosted job. This script prints the authoritative state so you can see
# whether a card fixed it.
#
# Requires the 'user' scope:  gh auth refresh -h github.com -s user

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../install/_lib.sh"
source "${HOST_ENV}"

GH_TOKEN="${GITHUB_TOKEN:-}"
[[ -z "$GH_TOKEN" && -f "$GITHUB_TOKEN_FILE" ]] && GH_TOKEN=$(cat "$GITHUB_TOKEN_FILE")
[[ -z "$GH_TOKEN" ]] && have gh && GH_TOKEN=$(gh auth token 2>/dev/null || true)
[[ -n "$GH_TOKEN" ]] || die "no GitHub token available"

api() {
  curl -fsS -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com$1"
}

log "=== GitHub billing / actions state ==="

# --- account ---------------------------------------------------------------
echo
log "account"
api "/user" | jq '{login, plan: (.plan.name // "n/a"), two_factor: .two_factor_authentication}' 2>/dev/null || warn "could not read /user"

# --- actions billing -------------------------------------------------------
echo
log "actions billing (this is the endpoint that shows a lock)"
BILL=$(api "/users/${GITHUB_USER}/settings/billing/actions" 2>&1)
if [[ "$BILL" == \{* ]]; then
  echo "$BILL" | jq '{total_minutes_used, total_paid_minutes_used, included_minutes}' 2>/dev/null || echo "$BILL"
  echo
  note "the current model expresses included compute in USD, not minutes"
else
  warn "$BILL"
  note "if this says 404 or 403, the token is missing the 'user' scope:"
  note "  gh auth refresh -h github.com -s user"
fi

# --- shared storage --------------------------------------------------------
echo
log "shared storage"
api "/users/${GITHUB_USER}/settings/billing/shared-storage" 2>/dev/null \
  | jq '{days_left_in_billing_cycle, estimated_paid_storage_for_orgs_in_gb, estimated_paid_storage_for_users_in_gb}' 2>/dev/null \
  || warn "could not read shared storage billing"

# --- action minutes for one repo (newer API shape) -------------------------
echo
log "recent runs (are jobs starting at all?)"
api "/repos/${GITHUB_OWNER}/agent-library/actions/runs?per_page=5" 2>/dev/null \
  | jq -r '.workflow_runs[]? | "\(.created_at)  \(.name // .path)  \(.status)/\(.conclusion)"' 2>/dev/null \
  | sed 's/^/  /' || warn "could not list runs"

echo
log "self-hosted runners (these keep working under a lock)"
api "/users/${GITHUB_USER}/actions/runners" 2>/dev/null \
  | jq -r '.runners[]? | "  \(.name)  \(.status)  \(.busy)  [\(.labels|map(.name)|join(","))]"' 2>/dev/null \
  || warn "no runners registered"

echo
log "check suites on the newest commit (did CI ever run?)"
SHA=$(api "/repos/${GITHUB_OWNER}/agent-library/commits/main" 2>/dev/null | jq -r '.sha // empty')
if [[ -n "$SHA" ]]; then
  api "/repos/${GITHUB_OWNER}/agent-library/commits/${SHA}/check-suites" 2>/dev/null \
    | jq -r '.check_suites[]? | "  app=\(.app.slug)  status=\(.status)  conclusion=\(.conclusion)"' 2>/dev/null
  echo
  note "app=github-actions with conclusion=startup_failure means the lock is still on"
fi
