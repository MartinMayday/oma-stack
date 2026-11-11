#!/usr/bin/env bash
# mirror/mirror-sync.sh — GitHub -> Forgejo, ONE DIRECTION ONLY.
#
# Run by systemd every ${MIRROR_INTERVAL_MIN} minutes.
#
# SAFETY: this never runs `git push --mirror`. A `--mirror` push would delete
# any Forgejo branch that does not exist on GitHub, and would also copy
# refs/remotes/* into the remote. We push two explicit refspecs instead:
#   +refs/heads/*:refs/heads/*   +refs/tags/*:refs/tags/*
# so the Forgejo side can only ever receive GitHub branches and tags.
#
# Credentials are read from files, never from the URL, so they never land in
# .git/config or in a process listing.
#
# TEST HOOK: set FF_FAKE_GITHUB and FF_FAKE_FORGEJO to override the two
# remote URLs. Useful for rehearsing a sync against local bare repos:
#   FF_FAKE_GITHUB=/srv/fake-github FF_FAKE_FORGEJO=/srv/fake-forgejo/repo.git \
#     ./mirror-sync.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../install/_lib.sh"
source "${HOST_ENV}"

FORGEJO_URL="${FORGEJO_URL:-http://127.0.0.1:3000}"
FORGEJO_OWNER="${FORGEJO_USER}"
MIRROR_ROOT="${MIRROR_CACHE}"

# Base URL of the Forgejo instance. FF_FAKE_FORGEJO replaces it for tests; it
# is a base, not a full repo URL — the owner/repo path is appended, exactly
# like FF_FAKE_GITHUB.
FORGEJO_REMOTE_BASE="${FF_FAKE_FORGEJO:-http://${FORGEJO_OWNER}@127.0.0.1:3000}"

# --- credentials -----------------------------------------------------------
GITHUB_TOKEN=""
[[ -f "$GITHUB_TOKEN_FILE" ]] && GITHUB_TOKEN=$(cat "$GITHUB_TOKEN_FILE")
[[ -z "$GITHUB_TOKEN" ]] && have gh && GITHUB_TOKEN=$(gh auth token 2>/dev/null || true)
if [[ -z "$GITHUB_TOKEN" ]]; then
  die "no GitHub token in ${GITHUB_TOKEN_FILE} (need 'repo' scope for private repos)"
fi

FORGEJO_TOKEN=""
[[ -f "$FORGEJO_TOKEN_FILE" ]] && FORGEJO_TOKEN=$(cat "$FORGEJO_TOKEN_FILE")
[[ -z "$FORGEJO_TOKEN" ]] && die "no Forgejo token in ${FORGEJO_TOKEN_FILE}"

# --- helpers ---------------------------------------------------------------
# A single askpass helper serves both remotes: it answers "Username" with
# x-access-token and "Password" with the token in FORCE_ASKPASS_TOKEN. The
# token is passed through the environment, never through argv, so it never
# shows up in `ps`.
export GIT_ASKPASS
export FORCE_ASKPASS_TOKEN

write_askpass() {
  cat >"$1" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  *Username*) printf '%s\n' "x-access-token" ;;
  *)          printf '%s\n' "$FORCE_ASKPASS_TOKEN" ;;
esac
EOS
  chmod 0700 "$1"
}

ASKPASS_FILE="$(mktemp -t askpass.XXXXXX)"
write_askpass "$ASKPASS_FILE"
export GIT_ASKPASS="$ASKPASS_FILE"
trap 'rm -f "$ASKPASS_FILE"' EXIT

# --- per-repo sync ---------------------------------------------------------
sync_repo() {
  local slug="$1"          # owner/repo
  local name="${slug#*/}"
  local bare="${MIRROR_ROOT}/${name}.git"

  install -d "$MIRROR_ROOT"

  # 1. fetch from GitHub into a local bare cache
  if [[ ! -d "$bare" ]]; then
    log "cloning ${slug}"
    # Full clone, NOT --filter=blob:none. A partial clone would make the
    # push below fail with "missing blob" errors, because the objects are not
    # local. Disk is 4 TB; correctness matters more.
    FORCE_ASKPASS_TOKEN="$GITHUB_TOKEN" git clone --bare \
      "${FF_FAKE_GITHUB:-https://github.com}/${slug}.git" "$bare" 2>&1 | tail -2 || {
        warn "clone of ${slug} failed"
        return 1
      }
  else
    FORCE_ASKPASS_TOKEN="$GITHUB_TOKEN" git -C "$bare" fetch --prune \
      --tags origin "+refs/heads/*:refs/heads/*" 2>&1 | tail -2 || {
        warn "fetch of ${slug} failed"
        return 1
      }
  fi

  # 2. push to Forgejo with explicit refspecs (never --mirror)
  git -C "$bare" remote remove forgejo 2>/dev/null || true
  git -C "$bare" remote add forgejo "${FORGEJO_REMOTE_BASE}/${FORGEJO_OWNER}/${name}.git"

  # The '+' prefix means force. That is correct here and only here: the
  # Forgejo repo is a mirror of GitHub, so GitHub is authoritative and the
  # Forgejo side must be reset to match it. Without the force, a branch that
  # diverged (a GitHub force-push, or the repo's initial commit) would make
  # every sync fail forever.
  #
  # This still is NOT `git push --mirror`: the refspecs are explicit, so
  # refs/remotes/* and any other namespace is never touched, and GitHub is
  # never a push target. The only deletions possible are branches in the
  # Forgejo mirror that do not exist on GitHub — which is exactly what a
  # mirror should do.
  # Note: the push runs inside an `if` condition so that a failure does not
  # trip `set -e` before we can report it.
  #
  # No --prune: a branch that exists only in Forgejo (a fix you pushed there
  # during the outage) is left alone. Only the branches and tags that GitHub
  # has are written. The cost is that a branch deleted on GitHub lingers in
  # Forgejo until you delete it there too.
  if PUSH_OUT=$(FORCE_ASKPASS_TOKEN="$FORGEJO_TOKEN" git -C "$bare" push --quiet \
      forgejo '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' 2>&1); then
    ok "${slug} -> forgejo/${name}"
  else
    warn "push of ${slug} to forgejo failed"
    printf '%s\n' "$PUSH_OUT" | tail -5 | sed 's/^/       /'
    return 1
  fi
}

# --- main ------------------------------------------------------------------
log "mirror sync starting"

# The mirror cache lives on the internal SSD, so this script does not depend
# on the USB disk being mounted. The USB is for backups only.

FAILED=0
for slug in $MIRROR_REPOS; do
  sync_repo "$slug" || FAILED=$((FAILED+1))
done

if (( FAILED > 0 )); then
  warn "${FAILED} repo(s) failed to sync"
  exit 1
fi

# Stamp the sync time so healthcheck.sh can measure freshness.
install -d "$MIRROR_ROOT"
date -u +%Y-%m-%dT%H:%M:%SZ >"${MIRROR_ROOT}/.last-sync"
ok "mirror sync complete"
