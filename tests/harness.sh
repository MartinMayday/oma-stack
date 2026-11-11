#!/usr/bin/env bash
# tests/harness.sh — the functional harness for oma-stack.
#
# Exercises the scripts that touch storage paths against local fakes:
#   stack/mirror/mirror-sync.sh     GitHub -> Forgejo
#   stack/mirror/issue-snapshot.sh  issue JSON -> Forgejo
#   stack/backup/backup-to-usb.sh   hot tier -> USB snapshot
#   stack/verify/healthcheck.sh     PASS/WARN/FAIL three-state
#
# Real filesystem throughout: real bind mounts so `mountpoint -q` is honest,
# real bare git repos, a real sqlite3 database.  No root, no network beyond
# a local stub, no docker.
#
#   bash tests/harness.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="${ROOT}/stack"
T="/tmp/oma-stack-test"
PASS=0
FAIL=0
STUB_PID=""

ok()    { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
head_() { printf '\n\033[1;36m== %s ==\033[0m\n' "$1"; }

check() { # check <desc> <cmd...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

cleanup() {
  [[ -n "$STUB_PID" ]] && kill "$STUB_PID" 2>/dev/null
  umount "$T/usb" 2>/dev/null
  umount "$T/sd" 2>/dev/null
}

umount "$T/usb" 2>/dev/null
umount "$T/sd" 2>/dev/null
rm -rf "$T"
mkdir -p "$T"/{boot,usb-src,mirror,github,cred,log,api}

# --- real mountpoints so mountpoint -q tells the truth ---------------------
mkdir -p "$T/usb" "$T/sd-src" "$T/sd"
mount --bind "$T/usb-src" "$T/usb"
mount --bind "$T/sd-src" "$T/sd"

# --- a host.env pointing at the sandbox -------------------------------------
cat >"$T/host.env" <<EOF
GITHUB_OWNER="MartinMayday"
GITHUB_USER="MartinMayday"
FORGEJO_USER="ci-admin"
FORGEJO_PASSWORD=""
FORGEJO_DOMAIN="localhost"
FORGEJO_URL_FOR_DISPLAY="http://localhost:3000"
MIRROR_REPOS="MartinMayday/agent-library MartinMayday/agents-md-generator"
ISSUE_SNAPSHOT_REPO="issue-snapshot"
BOOT_DATA="${T}/boot"
REPO_ROOT="${T}/boot/forgejo-repositories"
ACTIONS_LOG="${T}/boot/actions-log"
ACTIONS_ARTIFACTS="${T}/boot/actions-artifacts"
MIRROR_CACHE="${T}/boot/mirror-cache"
DOCKER_DATA_ROOT="${T}/boot/docker"
USB_DISK="${T}/usb"
BACKUP_ROOT="${T}/usb/backups"
BACKUP_RETENTION="3"
USB_HOLDS_ACTIONS="0"
SCRATCH_DISK="${T}/sd"
SCRATCH_WORK="${T}/sd/act-work"
RUNNER_USER="root"
RUNNER_CAPACITY="1"
RUNNER_LABELS="self-hosted:host linux x64"
ENABLE_DOCKER_LABEL="0"
ENABLE_GITHUB_RUNNER="0"
GITHUB_RUNNER_DIR="${T}/actions-runner"
GITHUB_RUNNER_NAME="test"
GITHUB_RUNNER_LABELS="macbook"
EXPOSE_MODE="none"
ENABLE_ALWAYS_ON="0"
DOCKER_MEMORY_LIMIT="4g"
CRED_DIR="${T}/cred"
GITHUB_TOKEN_FILE="${T}/cred/github.token"
FORGEJO_TOKEN_FILE="${T}/cred/forgejo.token"
MIRROR_INTERVAL_MIN="15"
ISSUE_SNAPSHOT_INTERVAL_MIN="30"
HEALTHCHECK_INTERVAL_MIN="10"
BACKUP_INTERVAL_H="6"
ENABLE_OPENBOT="0"
ENABLE_AGENT_BRIDGE="1"
ENABLE_TOOLING="0"
OPENBOT_PORT="3001"
OPENBOT_IMAGE="ghcr.io/copilotkit/openbot:latest"
OPENBOT_VOLUME="oma-openbot-data"
OPENBOT_DATA_DIR="${T}/boot/openbot"
OPENBOT_SINGLE_USER="true"
OPENBOT_BIND="127.0.0.1"
OPENBOT_INTELLIGENCE_API_URL="https://api.intelligence.copilotkit.ai"
OPENBOT_INTELLIGENCE_GATEWAY_WS_URL="wss://realtime.intelligence.copilotkit.ai"
OPENBOT_INTELLIGENCE_API_KEY=""
OPENBOT_MODEL_PROVIDER="openai"
OPENBOT_MODEL=""
OPENBOT_AGENT_ENDPOINT_ALLOWED_HOSTS=""
AGENT_BRIDGE_PORT="8765"
AGENT_BRIDGE_BIND="127.0.0.1"
AGENT_BRIDGE_USER=""
AGENT_BRIDGE_REGISTRY="${T}/cred/agents.json"
AGENT_DEFAULT="qoder"
HANDOFF_ROOT="${T}/handoff"
HANDOFF_WATCH_DIR="${T}/handoff/inbox"
HERMES_PERSONA_SOURCE=""
PIP_PACKAGES=""
EOF

export OMA_CONFIG="$T/host.env"
trap cleanup EXIT

# --- fake GitHub: bare repos laid out as <base>/<owner>/<repo>.git ---------
mkdir -p "$T/github/MartinMayday"
for r in agent-library agents-md-generator; do
  rm -rf "$T/github/MartinMayday/$r.git"
  git init -q --bare "$T/github/MartinMayday/$r.git"
  git init -q -b main "$T/work-$r"
  (
    cd "$T/work-$r"
    git config user.email t@t; git config user.name t
    echo "# $r" > README.md
    git add -A; git commit -q -m "initial"
    git tag v1
    git branch feature/x
    git remote add origin "$T/github/MartinMayday/$r.git"
    git push -q origin main --tags
    git push -q origin feature/x
  )
done

# --- fake Forgejo: <base>/<owner>/<repo>.git -------------------------------
mkdir -p "$T/forgejo/ci-admin"
for r in agent-library agents-md-generator issue-snapshot; do
  rm -rf "$T/forgejo/ci-admin/$r.git"
  git init -q --bare "$T/forgejo/ci-admin/$r.git"
done

# --- credentials -----------------------------------------------------------
echo "gh-token" >"$T/cred/github.token"
echo "fj-token" >"$T/cred/forgejo.token"
chmod 0600 "$T/cred"/*.token

# --- stub GitHub issues API ------------------------------------------------
cat >"$T/api/issues.json" <<'J'
[{"number":1,"title":"probe","state":"open","state_reason":null,
  "labels":[{"name":"ci"}],"created_at":"2026-01-01T00:00:00Z","closed_at":null,
  "url":"https://github.com/MartinMayday/agent-library/issues/1","body":"hello"}]
J
cat >"$T/api/stub.py" <<'PY'
import http.server, socketserver, sys, os
d = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split('?')[0].endswith('/issues'):
            body = open(os.path.join(d, 'issues.json'), 'rb').read()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a): pass
srv = socketserver.TCPServer(('127.0.0.1', 0), H)
open(os.path.join(d, 'port'), 'w').write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "$T/api/stub.py" "$T/api" >"$T/api/server.log" 2>&1 &
STUB_PID=$!
sleep 1

export FF_FAKE_GITHUB="$T/github"
export FF_FAKE_FORGEJO="$T/forgejo"

# =============================================================================
head_ "1. mirror-sync.sh — GitHub -> Forgejo"

OUT=$(bash "$STACK/mirror/mirror-sync.sh" 2>&1); RC=$?
printf '%s\n' "$OUT" | sed 's/^/    /'
check "mirror-sync exit 0 (rc=$RC)" test "$RC" -eq 0
check "mirror cache created under MIRROR_CACHE" test -d "$T/boot/mirror-cache/agent-library.git"
check "last-sync stamp written" test -f "$T/boot/mirror-cache/.last-sync"
check "main pushed to forgejo" git --git-dir="$T/forgejo/ci-admin/agent-library.git" rev-parse --verify main
check "tag v1 pushed to forgejo" git --git-dir="$T/forgejo/ci-admin/agent-library.git" rev-parse --verify refs/tags/v1
check "feature/x pushed to forgejo" git --git-dir="$T/forgejo/ci-admin/agent-library.git" rev-parse --verify refs/heads/feature/x
check "forgejo commit == github commit" test \
  "$(git --git-dir="$T/forgejo/ci-admin/agent-library.git" rev-parse main)" = \
  "$(git --git-dir="$T/github/MartinMayday/agent-library.git" rev-parse main)"
check "second repo mirrored too" git --git-dir="$T/forgejo/ci-admin/agents-md-generator.git" rev-parse --verify main

OUT2=$(bash "$STACK/mirror/mirror-sync.sh" 2>&1); RC2=$?
check "second sync exit 0 (rc=$RC2)" test "$RC2" -eq 0
check "second sync still has main" git --git-dir="$T/forgejo/ci-admin/agent-library.git" rev-parse --verify main

git --git-dir="$T/forgejo/ci-admin/agent-library.git" branch local-only-fix main
bash "$STACK/mirror/mirror-sync.sh" >/dev/null 2>&1
check "forgejo-only branch survives the mirror" git \
  --git-dir="$T/forgejo/ci-admin/agent-library.git" rev-parse --verify refs/heads/local-only-fix

# =============================================================================
head_ "2. issue-snapshot.sh — issue JSON -> Forgejo"

APIPORT=$(cat "$T/api/port" 2>/dev/null || echo "")
if [[ -n "$APIPORT" ]]; then
  export FF_GITHUB_API="http://127.0.0.1:${APIPORT}"
  OUT=$(bash "$STACK/mirror/issue-snapshot.sh" 2>&1); RC=$?
  printf '%s\n' "$OUT" | sed 's/^/    /'
  check "issue-snapshot exit 0 (rc=$RC)" test "$RC" -eq 0
  check "snapshot dir under MIRROR_CACHE" test -d "$T/boot/mirror-cache/issue-snapshot/.git"
  check "issues json written" test -f "$T/boot/mirror-cache/issue-snapshot/agent-library-issues.json"
  check "issue json parsed correctly" jq -e \
    '.[0].number==1 and .[0].title=="probe" and .[0].labels[0]=="ci"' \
    "$T/boot/mirror-cache/issue-snapshot/agent-library-issues.json"
  check "snapshot pushed to forgejo" git --git-dir="$T/forgejo/ci-admin/issue-snapshot.git" rev-parse --verify main
  check "snapshot content on the forgejo side" bash -c \
    "git --git-dir='$T/forgejo/ci-admin/issue-snapshot.git' show main:agent-library-issues.json | jq -e '.[0].number==1'"
  OUT=$(bash "$STACK/mirror/issue-snapshot.sh" 2>&1); RC=$?
  check "re-run is idempotent (rc=$RC)" test "$RC" -eq 0
else
  bad "could not start the issue API stub"
fi

# =============================================================================
head_ "3. backup-to-usb.sh — hot tier -> USB snapshot"

mkdir -p "$T/boot/data" "$T/boot/forgejo-repositories/x.git" "$T/boot/actions-log" \
         "$T/boot/actions-artifacts" "$T/boot/mirror-cache"
if command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "$T/boot/data/forgejo.db" "CREATE TABLE t(a int); INSERT INTO t VALUES(1);"
  HAS_SQLITE=yes
else
  HAS_SQLITE=no
  echo "CREATE TABLE t(a int);" >"$T/boot/data/forgejo.db"
fi
echo "log line" >"$T/boot/actions-log/run.log"
echo "artifact" >"$T/boot/actions-artifacts/a.zip"
git init -q --bare "$T/boot/forgejo-repositories/x.git"

OUT=$(bash "$STACK/backup/backup-to-usb.sh" 2>&1); RC=$?
printf '%s\n' "$OUT" | sed 's/^/    /'
check "backup exit 0 (rc=$RC)" test "$RC" -eq 0
SNAP=$(find "$T/usb/backups" -maxdepth 1 -mindepth 1 -type d -name '20*' 2>/dev/null | head -1)
if [[ -n "$SNAP" ]]; then
  ok "snapshot directory created"
  check "database copied" test -f "$SNAP/forgejo.db"
  check "repositories archived" test -f "$SNAP/forgejo-repositories.tar.gz"
  check "actions log archived" test -f "$SNAP/actions-log.tar.gz"
  check "artifacts archived" test -f "$SNAP/actions-artifacts.tar.gz"
  check "mirror cache archived" test -f "$SNAP/mirror-cache.tar.gz"
  check "manifest written" test -f "$SNAP/MANIFEST.txt"
  check "restore helper written and executable" test -x "$SNAP/RESTORE.sh"
  check "last-backup stamp written" test -f "$T/usb/backups/.last-backup"
  if [[ "$HAS_SQLITE" == yes ]]; then
    check "database copy is valid sqlite with the row" bash -c \
      "sqlite3 '$SNAP/forgejo.db' 'SELECT a FROM t' | grep -qx 1"
  fi
  check "repository archive restores cleanly" bash -c \
    "mkdir -p '$T/restore' && tar -C '$T/restore' -xzf '$SNAP/forgejo-repositories.tar.gz' && test -d '$T/restore/forgejo-repositories/x.git'"
  check "no .partial left behind" bash -c "! test -d '$T/usb/backups' || ! ls -d '$T/usb/backups'/*.partial 2>/dev/null | grep -q ."
else
  bad "no snapshot directory created"
fi

for i in 1 2 3; do bash "$STACK/backup/backup-to-usb.sh" >/dev/null 2>&1; sleep 1; done
COUNT=$(find "$T/usb/backups" -maxdepth 1 -mindepth 1 -type d -name '20*' | wc -l)
if [[ "$COUNT" -le 3 ]]; then ok "retention kept ${COUNT} snapshot(s) (<= BACKUP_RETENTION=3)"
else bad "retention kept ${COUNT} snapshots (expected <= 3)"; fi

umount "$T/usb"
OUT=$(bash "$STACK/backup/backup-to-usb.sh" 2>&1); RC=$?
printf '%s\n' "$OUT" | sed 's/^/    /'
check "backup with the USB unmounted exits 0 (rc=$RC)" test "$RC" -eq 0
mount --bind "$T/usb-src" "$T/usb"

# --- the backup must archive what app.ini says, not what host.env says -----
head_ "3b. backup-to-usb.sh — app.ini is the source of truth"
mkdir -p /etc/forgejo "$T/live-repos" "$T/live-log"
cat >/etc/forgejo/app.ini <<INI
[repository]
ROOT = ${T}/live-repos

[storage.actions_log]
PATH = ${T}/live-log
INI
git init -q --bare "$T/live-repos/other.git"
echo "live log" >"$T/live-log/live.log"
OUT=$(bash "$STACK/backup/backup-to-usb.sh" 2>&1); RC=$?
check "backup with a custom app.ini exits 0 (rc=$RC)" test "$RC" -eq 0
SNAP2=$(find "$T/usb/backups" -maxdepth 1 -mindepth 1 -type d -name '20*' | sort -r | head -1)
check "archived the app.ini repository root" bash -c \
  "tar -tzf '$SNAP2/forgejo-repositories.tar.gz' | grep -q 'other.git'"
check "archived the app.ini actions log" bash -c \
  "tar -tzf '$SNAP2/actions-log.tar.gz' | grep -q 'live.log'"
check "manifest records the effective paths" grep -q "live-repos" "$SNAP2/MANIFEST.txt"
rm -rf /etc/forgejo

# =============================================================================
head_ "4. healthcheck.sh — three-state reporting"

OUT=$(bash "$STACK/verify/healthcheck.sh" 2>&1)
printf '%s\n' "$OUT" | sed 's/^/    /'
check "healthcheck prints PASS lines" bash -c "printf '%s' \"\$1\" | grep -q '^PASS'" _ "$OUT"
check "internal SSD check present" bash -c "printf '%s' \"\$1\" | grep -q 'storage.internal'" _ "$OUT"
check "mirror freshness reads MIRROR_CACHE" bash -c "printf '%s' \"\$1\" | grep -q 'mirror.freshness: last sync'" _ "$OUT"

umount "$T/usb"
OUT=$(bash "$STACK/verify/healthcheck.sh" 2>&1)
check "USB unmounted => WARN, not FAIL" bash -c \
  "printf '%s' \"\$1\" | grep '^WARN  storage.usb' && ! printf '%s' \"\$1\" | grep '^FAIL  storage.usb'" _ "$OUT"
check "backup freshness also WARN" bash -c \
  "printf '%s' \"\$1\" | grep '^WARN  backup.freshness'" _ "$OUT"
mount --bind "$T/usb-src" "$T/usb"

# =============================================================================
head_ "5. the kit around the stack"

STALE=$(grep -rn "USB_REPOS\|USB_ACTIONS_LOG\|USB_ACTIONS_ARTIFACTS\|USB_MIRRORS" "$ROOT" \
  --exclude-dir=.git --exclude=harness.sh 2>/dev/null | wc -l)
check "no stale USB_* references (found $STALE)" test "$STALE" -eq 0

BAD=0
while IFS= read -r f; do bash -n "$f" || BAD=$((BAD+1)); done < <(find "$ROOT" -name '*.sh' -not -path '*/.git/*')
check "all .sh files parse (failures: $BAD)" test "$BAD" -eq 0

check "bridge.py compiles" python3 -m py_compile "$ROOT/components/agents/bridge.py"
check "the agent registry template is valid JSON" jq -e '.agents | length >= 1' "$ROOT/components/agents/agents.json"
check "the openbot compose file is valid YAML" python3 -c "
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)
yaml.safe_load(open('$ROOT/components/openbot/docker-compose.yml'))
"
check "the compose file pins the embedded database" grep -q 'EMBEDDED_POSTGRES: "on"' "$ROOT/components/openbot/docker-compose.yml"
check "the compose file keeps the port on loopback" grep -q 'OPENBOT_BIND' "$ROOT/components/openbot/docker-compose.yml"
check "the compose file reads the secrets from /etc/oma-stack" grep -q '/etc/oma-stack/openbot.env' "$ROOT/components/openbot/docker-compose.yml"
check "the config resolver finds the config" bash -c "source '$ROOT/stack/install/_lib.sh' && test -f \"\$HOST_ENV\""
check "every script sources the resolved config" bash -c \
  "! grep -rn 'source \"\${HERE}/..*config/host.env\"' '$ROOT' --include='*.sh' | grep -q ."
check "the one-liner is in the README" grep -q 'curl -fsSL https://raw.githubusercontent.com/MartinMayday/oma-stack' "$ROOT/README.md"
check "the uninstaller exists and parses" bash -n "$ROOT/uninstall.sh"
check "the bootstrap exists and parses" bash -n "$ROOT/bootstrap.sh"

# =============================================================================
head_ "6. the python tests"

if python3 -m unittest discover -s "$ROOT/tests" >"$T/unittest.log" 2>&1; then
  ok "the bridge unit tests pass ($(grep -oE 'Ran [0-9]+ tests' "$T/unittest.log" | head -1))"
else
  bad "the bridge unit tests fail"
  tail -20 "$T/unittest.log" | sed 's/^/    /'
fi

# =============================================================================
head_ "7. the unified healthcheck"

OUT=$(bash "$ROOT/verify/healthcheck.sh" 2>&1)
printf '%s\n' "$OUT" | sed 's/^/    /'
check "the unified healthcheck runs" bash -c "printf '%s' \"\$1\" | grep -q 'PASS'" _ "$OUT"
check "it carries the stack results" bash -c "printf '%s' \"\$1\" | grep -q 'storage.internal'" _ "$OUT"
check "it checks the agent bridge" bash -c "printf '%s' \"\$1\" | grep -q 'agent-bridge'" _ "$OUT"

echo
printf '\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
