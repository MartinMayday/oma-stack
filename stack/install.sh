#!/usr/bin/env bash
# install.sh — run every install step in order.
#
#   sudo ./install.sh              full install
#   sudo ./install.sh --no-runner  skip the two runners (Forgejo server only)
#   sudo ./install.sh --skip X,Y   skip steps by number
#
# Re-running is safe: every step checks whether it already did its job.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/install/_lib.sh"
source "${HOST_ENV}"

SKIP=""
DO_RUNNERS=1
while (( $# )); do
  case "$1" in
    --no-runner) DO_RUNNERS=0; shift ;;
    --skip=*)    SKIP="${SKIP},${1#--skip=}"; shift ;;
    --skip)      shift; SKIP="${SKIP},${1:-}"; shift ;;
    *)           die "unknown option: $1" ;;
  esac
done

skip_step() {
  [[ ",${SKIP}," == *",$1,"* ]]
}

run_step() {
  local num="$1" script="$2"
  if skip_step "$num"; then
    warn "skipping ${script} (--skip ${num})"
    return 0
  fi
  echo
  printf '\033[1;35m########## %s ##########\033[0m\n' "${script}"
  bash "${HERE}/install/${script}"
}
need_root

# Make sure the package is executable
chmod +x "${HERE}"/install/*.sh "${HERE}"/mirror/*.sh "${HERE}"/verify/*.sh "${HERE}"/backup/*.sh 2>/dev/null || true

run_step 00 00-preflight.sh
run_step 10 10-forgejo.sh
if (( DO_RUNNERS )); then
  run_step 20 20-forgejo-runner.sh
  run_step 30 30-github-runner.sh
else
  warn "skipping both runners (--no-runner)"
fi
run_step 40 40-exposure.sh
run_step 50 50-always-on.sh
run_step 60 60-timers.sh
run_step 70 70-backup.sh

echo
printf '\033[1;35m########## mirrors ##########\033[0m\n'
bash "${HERE}/mirror/setup-mirrors.sh"

echo
printf '\033[1;35m########## selftest ##########\033[0m\n'
bash "${HERE}/verify/selftest.sh" || warn "selftest did not pass — see the output above"

cat <<EOF

=================================================================
  oma stack installed.

  Forgejo (CI + mirror + issues)  : ${FORGEJO_URL:-http://127.0.0.1:3000}
  Admin user                      : ${FORGEJO_USER}
  GitHub self-hosted runner        : ${GITHUB_RUNNER_NAME} (${ENABLE_GITHUB_RUNNER})
  Mirror direction                 : GitHub -> Forgejo (one way, never push --mirror)

  Storage
    internal SSD (hot)             : ${BOOT_DATA}
      repos ${REPO_ROOT}
      actions log ${ACTIONS_LOG}
      artifacts ${ACTIONS_ARTIFACTS}
      mirror cache ${MIRROR_CACHE}
    USB SATA (bulk + backups)      : ${BACKUP_ROOT} (keep ${BACKUP_RETENTION}, every ${BACKUP_INTERVAL_H}h)
    SD card (optional scratch)     : $(runner_workdir)

  Next:
    1. Save the Forgejo admin password printed earlier.
    2. Read  docs/RUNBOOK.md          — what to do when GitHub blocks you
    3. Read  docs/GITHUB-BILLING-CHECKLIST.md — fix the card on file
    4. Put a GitHub PAT (repo scope) in ${GITHUB_TOKEN_FILE}, mode 0600
    5. Health:  sudo ${HERE}/../verify/healthcheck.sh
=================================================================
EOF
