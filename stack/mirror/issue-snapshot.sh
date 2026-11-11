#!/usr/bin/env bash
# mirror/issue-snapshot.sh — publish a read-only snapshot of GitHub issues.
#
# GitHub issues are NOT continuously mirrored by git. This writes a JSON
# snapshot of every issue into a dedicated Forgejo repo on a timer, so the
# the oma stack has an offline copy of the tracker.
#
# The tracker of record stays GitHub. This is a snapshot, not a second source
# of truth.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../install/_lib.sh"
source "${HOST_ENV}"

SNAP_DIR="${MIRROR_CACHE}/issue-snapshot"
FORGEJO_URL="${FORGEJO_URL:-http://127.0.0.1:3000}"
FORGEJO_OWNER="${FORGEJO_USER}"

# TEST HOOK: point the API at a local stub instead of api.github.com.
GITHUB_API="${FF_GITHUB_API:-https://api.github.com}"

# TEST HOOK: point the Forgejo remote at a local bare repo instead of the
# server. Base URL — the owner/repo path is appended.
FORGEJO_REMOTE_BASE="${FF_FAKE_FORGEJO:-http://${FORGEJO_OWNER}@127.0.0.1:3000}"

# --- credentials -----------------------------------------------------------
GITHUB_TOKEN=""
[[ -f "$GITHUB_TOKEN_FILE" ]] && GITHUB_TOKEN=$(cat "$GITHUB_TOKEN_FILE")
[[ -z "$GITHUB_TOKEN" ]] && have gh && GITHUB_TOKEN=$(gh auth token 2>/dev/null || true)
[[ -n "$GITHUB_TOKEN" ]] || die "no GitHub token available"

FORGEJO_TOKEN=""
[[ -f "$FORGEJO_TOKEN_FILE" ]] && FORGEJO_TOKEN=$(cat "$FORGEJO_TOKEN_FILE")
[[ -z "$FORGEJO_TOKEN" ]] && die "no Forgejo token in ${FORGEJO_TOKEN_FILE}"

export GIT_ASKPASS
ASKPASS_FILE="$(mktemp -t askpass.XXXXXX)"
trap 'rm -f "$ASKPASS_FILE"' EXIT
cat >"$ASKPASS_FILE" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  *Username*) printf '%s\n' "x-access-token" ;;
  *)          printf '%s\n' "$FORCE_ASKPASS_TOKEN" ;;
esac
EOS
chmod 0700 "$ASKPASS_FILE"

# --- snapshot --------------------------------------------------------------
install -d "$SNAP_DIR"
cd "$SNAP_DIR"

if [[ ! -d .git ]]; then
  git init -q -b main .
  git remote add forgejo "${FORGEJO_REMOTE_BASE}/${FORGEJO_OWNER}/${ISSUE_SNAPSHOT_REPO}.git"
fi

printf '# GitHub issue snapshot\n\nGenerated %s by mirror/issue-snapshot.sh.\n\nGitHub remains the tracker of record.\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >README.md

for slug in $MIRROR_REPOS; do
  name="${slug#*/}"
  curl -fsS -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${GITHUB_API}/repos/${slug}/issues?state=all&per_page=100" \
    | jq '[.[] | {number, title, state, state_reason, labels: [.labels[].name],
                created_at, closed_at, url, body}]' \
    >"${name}-issues.json" || warn "issue fetch failed for ${slug}"
done

git add -A
if git diff --cached --quiet; then
  ok "issue snapshot unchanged"
  exit 0
fi
git -c user.name="oma-stack" -c user.email="forge@localhost" \
    commit -q -m "chore(sync): issue snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)"
FORCE_ASKPASS_TOKEN="$FORGEJO_TOKEN" git push -q forgejo main || warn "push failed"
ok "issue snapshot published to forgejo/${ISSUE_SNAPSHOT_REPO}"
