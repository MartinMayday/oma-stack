#!/usr/bin/env bash
# verify/selftest.sh — prove the oma stack actually runs CI.
#
# A stack that installs is not a stack that works. This pushes a real workflow
# to the Forgejo mirror of a repo and waits for the runner to execute it.
#
# Usage:  sudo ./verify/selftest.sh [owner/repo]

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../install/_lib.sh"
source "${HOST_ENV}"

FORGEJO_URL="${FORGEJO_URL:-http://127.0.0.1:3000}"
FORGEJO_OWNER="${FORGEJO_USER}"
TARGET="${1:-${MIRROR_REPOS%% *}}"
NAME="${TARGET#*/}"

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

log "selftest against ${TARGET} (forgejo/${NAME})"

# --- 1. the runner must be online ------------------------------------------
RUNNERS=$(api GET "/repos/${FORGEJO_OWNER}/${NAME}/actions/runners" 2>/dev/null || echo '{}')
ONLINE=$(printf '%s' "$RUNNERS" | jq -r '[.runners[]? | select(.status=="online")] | length' 2>/dev/null || echo 0)
if (( ONLINE == 0 )); then
  warn "no runner online for ${NAME}"
  note "check: systemctl status forgejo-runner.service"
  note "register: open ${FORGEJO_URL}/${FORGEJO_OWNER}/${NAME}/settings/actions/runners"
  exit 1
fi
ok "${ONLINE} runner(s) online"

# --- 2. push a workflow and wait for a run ---------------------------------
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

mkdir -p "${WORKDIR}/.forgejo/workflows"
cat >"${WORKDIR}/.forgejo/workflows/selftest.yml" <<'YML'
name: oma-selftest
on:
  push:
    branches: [main]
jobs:
  selftest:
    runs-on: [self-hosted, linux, x64]
    steps:
      - run: echo "FALLBACK_SELFTEST_OK $(date -u +%FT%TZ)"
      - run: git --version
YML

cd "$WORKDIR"
git init -q -b main .
git config user.name "oma-selftest"
git config user.email "selftest@localhost"
git add -A
git commit -q -m "chore: fallback selftest"

export GIT_ASKPASS
ASKPASS_FILE="$(mktemp -t askpass.XXXXXX)"
cat >"$ASKPASS_FILE" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  *Username*) printf '%s\n' "x-access-token" ;;
  *)          printf '%s\n' "$FORCE_ASKPASS_TOKEN" ;;
esac
EOS
chmod 0700 "$ASKPASS_FILE"
export FORCE_ASKPASS_TOKEN="$FORGEJO_TOKEN"

git remote add forgejo "http://${FORGEJO_OWNER}@127.0.0.1:3000/${FORGEJO_OWNER}/${NAME}.git"
git push -q forgejo main || die "push to forgejo failed"

ok "workflow pushed, waiting for the runner to pick it up"

# --- 3. poll for a completed run -------------------------------------------
DEADLINE=$(( $(date +%s) + 300 ))
RUN_ID=""
while (( $(date +%s) < DEADLINE )); do
  RUNS=$(api GET "/repos/${FORGEJO_OWNER}/${NAME}/actions/runs?limit=10" 2>/dev/null || echo '{}')
  RUN_ID=$(printf '%s' "$RUNS" | jq -r '[.workflow_runs[]? | select(.name=="oma-selftest" or (.head_branch=="main"))] | sort_by(.id) | last | .id // empty' 2>/dev/null)
  if [[ -n "$RUN_ID" && "$RUN_ID" != "null" ]]; then
    STATUS=$(printf '%s' "$RUNS" | jq -r --argjson id "$RUN_ID" '.workflow_runs[] | select(.id==$id) | .status' 2>/dev/null)
    CONCL=$(printf '%s' "$RUNS" | jq -r --argjson id "$RUN_ID" '.workflow_runs[] | select(.id==$id) | (.conclusion // "")' 2>/dev/null)
    case "$STATUS" in
      completed)
        if [[ "$CONCL" == "success" ]]; then
          ok "run ${RUN_ID} completed: success"
          echo
          ok "SELFTEST PASSED — the oma stack CI executes real workflows"
          exit 0
        else
          warn "run ${RUN_ID} completed with conclusion '${CONCL}'"
          api GET "/repos/${FORGEJO_OWNER}/${NAME}/actions/runs/${RUN_ID}" | jq '.jobs[]? | {name, status, conclusion}' 2>/dev/null | sed 's/^/  /'
          exit 1
        fi
        ;;
      in_progress|queued|waiting|pending)
        note "run ${RUN_ID} status=${STATUS}"
        ;;
      *)
        note "run ${RUN_ID} status=${STATUS}"
        ;;
    esac
  else
    note "no run registered yet"
  fi
  sleep 10
done

warn "no completed run within 5 minutes"
note "open ${FORGEJO_URL}/${FORGEJO_OWNER}/${NAME}/actions"
exit 1
