#!/usr/bin/env bash
# mirror/setup-mirrors.sh — create the mirror repos inside Forgejo.
#
# One-time setup: creates one repo per entry in MIRROR_REPOS plus the issue
# snapshot repo, then runs the first sync.
#
# Run this AFTER install/10-forgejo.sh and BEFORE the timers are useful.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../install/_lib.sh"
source "${HOST_ENV}"

FORGEJO_URL="${FORGEJO_URL:-http://127.0.0.1:3000}"
FORGEJO_OWNER="${FORGEJO_USER}"

FORGEJO_TOKEN=""
[[ -f "$FORGEJO_TOKEN_FILE" ]] && FORGEJO_TOKEN=$(cat "$FORGEJO_TOKEN_FILE")
[[ -n "$FORGEJO_TOKEN" ]] || die "no Forgejo token in ${FORGEJO_TOKEN_FILE}"

api() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -fsS -X "$method" "${FORGEJO_URL}/api/v1${path}" \
      -H "Authorization: token ${FORGEJO_TOKEN}" \
      -H "Content-Type: application/json" -d "$body"
  else
    curl -fsS -X "$method" "${FORGEJO_URL}/api/v1${path}" \
      -H "Authorization: token ${FORGEJO_TOKEN}"
  fi
}

create_repo() {
  local name="$1" private="$2"
  if api GET "/repos/${FORGEJO_OWNER}/${name}" >/dev/null 2>&1; then
    ok "repo ${FORGEJO_OWNER}/${name} already exists"
    return 0
  fi
  api POST "/orgs/${FORGEJO_OWNER}/repos" \
    "{\"name\":\"${name}\",\"private\":${private},\"auto_init\":true,\"default_branch\":\"main\"}" \
    >/dev/null 2>&1 \
    && ok "created ${FORGEJO_OWNER}/${name}" \
    || warn "could not create ${name} (is '${FORGEJO_OWNER}' an organisation?)"
}

log "creating the mirror repositories in Forgejo"
for slug in $MIRROR_REPOS; do
  create_repo "${slug#*/}" true
done
create_repo "${ISSUE_SNAPSHOT_REPO}" false

echo
log "running the first sync"
"${HERE}/mirror-sync.sh" || warn "first sync had failures — re-run later"
"${HERE}/issue-snapshot.sh" || warn "issue snapshot failed — re-run later"

echo
ok "mirror setup complete"
