#!/usr/bin/env bash
# openbot-worker.sh — the scheduled half of OpenBot.
#
# The all-in-one image carries the app, the API and the browser the Bots
# drive, but no scheduler.  Upstream ships the routines sweep and the
# staged-attachment sweep as scripts that something outside the server
# process has to run on a schedule.
#
# The sweep runs *inside* the running server container, with that
# container's whole environment — so it sees the same DATABASE_URL, the same
# key encryption key and the same secrets as the server it talks to.  A
# separate worker container would have to be told the database URL, and in
# the embedded-PostgreSQL deployment that URL lives inside the container.
#
# Nothing here is destructive: the routines sweep fires the routines that are
# due, and the attachment sweep removes staged blobs that were never sent.

set -euo pipefail

PROJECT_DIR="${OPENBOT_PROJECT_DIR:-/opt/oma-stack/components/openbot}"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"
SERVICE="${OPENBOT_SERVICE:-openbot}"

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "no compose project at ${COMPOSE_FILE}" >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose is not available" >&2
  exit 1
fi

if ! docker compose -f "${COMPOSE_FILE}" ps --status running "${SERVICE}" 2>/dev/null | grep -q "${SERVICE}"; then
  echo "the OpenBot container is not running — nothing to sweep" >&2
  exit 0
fi

run_script() {
  local script="$1" label="$2"
  echo "== ${label}"
  docker compose -f "${COMPOSE_FILE}" exec -T "${SERVICE}" sh -c "
    cd /app/server 2>/dev/null || exit 0
    if [ -f '${script}' ]; then
      bun ${script}
    else
      echo '${script} is not present in this image version — skipped'
    fi
  "
}

# Routines: the scheduled Bots.  Without this, a routine never fires.
run_script "scripts/fire-routines.ts" "routines"

# Staged attachments: blobs that were uploaded but never sent.  Without
# this they pile up — upstream counts 32 unsent files and 256 MiB per
# person before it starts culling.
run_script "scripts/cull-staged-attachments.ts" "staged attachments"
