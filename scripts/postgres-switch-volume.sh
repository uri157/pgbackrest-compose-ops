#!/usr/bin/env bash
set -euo pipefail

# scripts/postgres-switch-volume.sh
# Switch POSTGRES_VOLUME in env/.env.compose to a new volume and restart the prod compose stack.
# Keeps old volume untouched (quarantine) for rollback.

usage() {
  cat <<'TXT'
Postgres Volume Switch (promote restored volume)

This script switches the production Postgres Docker volume by updating:
  <deploy-dir>/env/.env.compose  -> POSTGRES_VOLUME=<new_volume>

Then it restarts the docker compose stack (without deleting volumes) and validates health.

USAGE:
  bash scripts/postgres-switch-volume.sh --to <new_volume> [options]

REQUIRED:
  --to <new_volume>        Target Docker volume name to become the production POSTGRES_VOLUME

OPTIONS:
  --deploy-dir <path>      Default: repo root (or DEPLOY_DIR from config)
  --compose-file <path>    Default: <deploy-dir>/docker-compose.prod.yml
  --yes                    Non-interactive (no prompt)
  --force                  Continue even if the target volume is in use by running containers (dangerous)
  --stop-shadow            If target volume is in use, automatically stop ONLY restore/shadow compose projects
  --shadow-pattern <re>    Allowed compose project name regex for auto-stop (default: ^pgbackrest-restore-)
  --prod-project <name>    Explicit production compose project name (skips auto-detect)
  --no-validate            Skip health checks after restart
  --pull                   Run `docker compose ... up -d --pull always`
  --help                   Show this help

NOTES:
- By default, if the target volume is in use, the script aborts.
- With --stop-shadow, it will stop only compose projects matching --shadow-pattern.
- It will NEVER auto-stop the production compose project (safety guard).
- Rollback is simply running this script again with --to <old_volume>.

EXAMPLES:
  bash scripts/postgres-switch-volume.sh --to pgrestore_20260130T210000Z
  bash scripts/postgres-switch-volume.sh --to pgrestore_... --yes --stop-shadow
TXT
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/load-ops-config.sh
. "${SCRIPT_DIR}/lib/load-ops-config.sh"
load_ops_config "$SCRIPT_DIR"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$REPO_ROOT}"
COMPOSE_FILE=""
TO_VOL=""
YES=0
FORCE=0
STOP_SHADOW=0
SHADOW_PATTERN="${SHADOW_PATTERN:-^pgbackrest-restore-}"
PROD_PROJECT_EXPLICIT=""
NO_VALIDATE=0
DO_PULL=0
PROD_PROJECT_FALLBACK="${PROD_PROJECT_FALLBACK:-pgbackrest-prod}"

while [ $# -gt 0 ]; do
  case "$1" in
    --deploy-dir) DEPLOY_DIR="${2:?}"; shift 2 ;;
    --compose-file) COMPOSE_FILE="${2:?}"; shift 2 ;;
    --to) TO_VOL="${2:?}"; shift 2 ;;
    --yes) YES=1; shift ;;
    --force) FORCE=1; shift ;;
    --stop-shadow) STOP_SHADOW=1; shift ;;
    --shadow-pattern) SHADOW_PATTERN="${2:?}"; shift 2 ;;
    --prod-project) PROD_PROJECT_EXPLICIT="${2:?}"; shift 2 ;;
    --no-validate) NO_VALIDATE=1; shift ;;
    --pull) DO_PULL=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "${TO_VOL}" ]; then
  echo "Missing --to <new_volume>" >&2
  usage
  exit 2
fi

ENV_DIR="${DEPLOY_DIR}/env"
STATE_DIR="${DEPLOY_DIR}/state"
COMPOSE_ENV="${ENV_DIR}/.env.compose"
DEPLOY_ENV="${DEPLOY_DIR}/.env.deploy"
API_ENV="${ENV_DIR}/.env.api"
[ -n "${COMPOSE_FILE}" ] || COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.prod.yml"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }
need docker

if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose not available on this host." >&2
  exit 1
fi

if [ ! -f "${COMPOSE_FILE}" ]; then
  echo "Compose file not found: ${COMPOSE_FILE}" >&2
  exit 1
fi

mkdir -p "${ENV_DIR}" "${STATE_DIR}"
touch "${STATE_DIR}/volume-switches.log" || true
chmod 700 "${STATE_DIR}" || true
chmod 600 "${STATE_DIR}/volume-switches.log" || true

# Load current env (best effort)
set -a
[ -f "${COMPOSE_ENV}" ] && . "${COMPOSE_ENV}" || true
[ -f "${DEPLOY_ENV}" ] && . "${DEPLOY_ENV}" || true
set +a

FROM_VOL="${POSTGRES_VOLUME:-}"
if [ -z "${FROM_VOL}" ]; then
  if [ -f "${COMPOSE_ENV}" ]; then
    FROM_VOL="$(grep -E '^POSTGRES_VOLUME=' "${COMPOSE_ENV}" | tail -n1 | cut -d= -f2- || true)"
  fi
fi

if [ -z "${FROM_VOL}" ]; then
  echo "Could not determine current POSTGRES_VOLUME (missing in ${COMPOSE_ENV})." >&2
  exit 1
fi

# Verify target volume exists
if ! docker volume inspect "${TO_VOL}" >/dev/null 2>&1; then
  echo "Target volume does not exist: ${TO_VOL}" >&2
  echo "Create it or restore into it first." >&2
  exit 1
fi

# Determine current PROD compose project name (for safety guard).
# IMPORTANT: detect via CURRENT prod volume (FROM_VOL), not "any postgres container".
detect_prod_project() {
  if [ -n "${PROD_PROJECT_EXPLICIT}" ]; then
    echo "${PROD_PROJECT_EXPLICIT}"
    return 0
  fi

  local cid=""
  cid="$(docker ps --filter "volume=${FROM_VOL}" --format '{{.ID}}' | head -n1 || true)"
  if [ -n "${cid}" ]; then
    docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "${cid}" 2>/dev/null || true
    return 0
  fi

  # Fallback: your known prod naming (safe default)
  echo "${PROD_PROJECT_FALLBACK}"
}

PROD_PROJECT="$(detect_prod_project)"
[ -n "${PROD_PROJECT}" ] || PROD_PROJECT="${PROD_PROJECT_FALLBACK}"

list_in_use_containers() {
  docker ps --filter "volume=${TO_VOL}" --format '{{.ID}} {{.Names}}' || true
}

get_compose_project() {
  local cid="$1"
  docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "${cid}" 2>/dev/null || true
}

stop_shadow_projects_if_needed() {
  local lines=""
  lines="$(list_in_use_containers | sed '/^[[:space:]]*$/d' || true)"
  if [ -z "${lines}" ]; then
    return 0
  fi

  echo "Target volume is currently in use by:"
  echo "${lines}" | sed 's/^/  - /'
  echo

  if [ "${STOP_SHADOW}" -ne 1 ]; then
    echo "Stop the shadow stack first, or rerun with --stop-shadow (recommended) or --force (dangerous)." >&2
    return 1
  fi

  # Build unique list of compose projects using this volume
  local projects=()
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    local cid name proj
    cid="$(echo "$line" | awk '{print $1}')"
    name="$(echo "$line" | awk '{print $2}')"
    proj="$(get_compose_project "${cid}")"

    if [ -z "${proj}" ]; then
      echo "Refusing to auto-stop container without compose project label: ${name} (${cid})" >&2
      return 1
    fi

    if [ "${proj}" = "${PROD_PROJECT}" ]; then
      echo "Refusing to auto-stop production compose project '${PROD_PROJECT}' (container: ${name})." >&2
      return 1
    fi

    if ! echo "${proj}" | grep -Eq "${SHADOW_PATTERN}"; then
      echo "Refusing to auto-stop non-shadow project '${proj}' (container: ${name})." >&2
      echo "Allowed auto-stop projects must match regex: ${SHADOW_PATTERN}" >&2
      return 1
    fi

    projects+=("${proj}")
  done <<< "${lines}"

  local uniq_projects=""
  uniq_projects="$(printf "%s\n" "${projects[@]}" | sort -u || true)"

  echo "Auto-stopping shadow compose project(s):"
  echo "${uniq_projects}" | sed 's/^/  - /'
  echo

  if [ "${YES}" -ne 1 ]; then
    read -r -p "Type 'stop' to confirm stopping these shadow stacks: " ans
    if [ "${ans}" != "stop" ]; then
      echo "Cancelled."
      return 1
    fi
  fi

  while IFS= read -r proj; do
    [ -n "${proj}" ] || continue
    echo "Stopping shadow project: ${proj}"
    docker compose -p "${proj}" down
  done <<< "${uniq_projects}"

  local still=""
  still="$(list_in_use_containers | sed '/^[[:space:]]*$/d' || true)"
  if [ -n "${still}" ]; then
    echo "Target volume still in use after attempting to stop shadow projects:" >&2
    echo "${still}" | sed 's/^/  - /' >&2
    return 1
  fi

  return 0
}

# If target is in use, try to stop shadow (opt-in) or abort unless --force
in_use="$(docker ps --filter "volume=${TO_VOL}" --format '{{.Names}}' | tr '\n' ' ' | sed 's/[[:space:]]\+$//' || true)"
if [ -n "${in_use}" ] && [ "${FORCE}" -ne 1 ]; then
  stop_shadow_projects_if_needed || exit 1
fi

if [ "${FROM_VOL}" = "${TO_VOL}" ]; then
  echo "POSTGRES_VOLUME already set to: ${TO_VOL}"
  exit 0
fi

echo "About to switch production Postgres volume:"
echo "  PROD_PROJECT: ${PROD_PROJECT}"
echo "  FROM: ${FROM_VOL}"
echo "  TO:   ${TO_VOL}"
echo "  File: ${COMPOSE_ENV}"
echo

if [ "${YES}" -ne 1 ]; then
  read -r -p "Type 'switch' to confirm: " ans
  if [ "${ans}" != "switch" ]; then
    echo "Cancelled."
    exit 0
  fi
fi

# Update env file atomically
tmp="$(mktemp)"
if [ -f "${COMPOSE_ENV}" ]; then
  if grep -qE '^POSTGRES_VOLUME=' "${COMPOSE_ENV}"; then
    sed -E "s/^POSTGRES_VOLUME=.*/POSTGRES_VOLUME=${TO_VOL}/" "${COMPOSE_ENV}" > "${tmp}"
  else
    cat "${COMPOSE_ENV}" > "${tmp}"
    echo "POSTGRES_VOLUME=${TO_VOL}" >> "${tmp}"
  fi
else
  echo "POSTGRES_VOLUME=${TO_VOL}" > "${tmp}"
fi
mv "${tmp}" "${COMPOSE_ENV}"
chmod 600 "${COMPOSE_ENV}" || true

# Export env for compose interpolation
set -a
. "${COMPOSE_ENV}"
[ -f "${DEPLOY_ENV}" ] && . "${DEPLOY_ENV}" || true
set +a

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "${ts} | switch | from=${FROM_VOL} | to=${TO_VOL}" >> "${STATE_DIR}/volume-switches.log"

# Restart stack without deleting volumes
echo "Stopping compose stack (no volume deletion)..."
docker compose -f "${COMPOSE_FILE}" down

echo "Starting postgres/pgbackrest with new volume..."
docker compose -f "${COMPOSE_FILE}" up -d postgres pgbackrest

wait_for_pg_ready() {
  timeout="${1:-120}"
  interval=5
  start="$(date +%s)"
  while true; do
    if docker compose -f "${COMPOSE_FILE}" exec -T postgres sh -c \
      'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
      </dev/null >/dev/null 2>&1; then
      return 0
    fi
    now="$(date +%s)"
    if [ $((now - start)) -ge "${timeout}" ]; then
      echo "Timeout waiting for postgres" >&2
      docker compose -f "${COMPOSE_FILE}" logs --tail 200 postgres >&2 || true
      return 1
    fi
    sleep "${interval}"
  done
}

echo "Waiting for postgres..."
wait_for_pg_ready 180

echo "Starting full stack..."
if [ "${DO_PULL}" -eq 1 ]; then
  docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans --pull always --force-recreate
else
  docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans --force-recreate
fi

if [ "${NO_VALIDATE}" -eq 1 ]; then
  echo "Switched volume (validation skipped)."
  echo "FROM=${FROM_VOL} TO=${TO_VOL}"
  exit 0
fi

wait_for_health() {
  svc="$1"
  timeout="${2:-120}"
  interval=5
  start="$(date +%s)"
  while true; do
    cid="$(docker compose -f "${COMPOSE_FILE}" ps -q "${svc}" 2>/dev/null || true)"
    if [ -z "${cid}" ]; then
      echo "Missing container for ${svc}" >&2
      docker compose -f "${COMPOSE_FILE}" ps -a >&2 || true
      docker compose -f "${COMPOSE_FILE}" logs --tail 200 "${svc}" >&2 || true
      return 1
    fi
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}" 2>/dev/null || true)"
    case "${health}" in
      healthy) return 0 ;;
      unhealthy)
        echo "${svc} is unhealthy" >&2
        docker compose -f "${COMPOSE_FILE}" logs --tail 200 "${svc}" >&2 || true
        return 1
        ;;
    esac
    now="$(date +%s)"
    if [ $((now - start)) -ge "${timeout}" ]; then
      echo "Timeout waiting for ${svc} to be healthy (health=${health})" >&2
      docker compose -f "${COMPOSE_FILE}" logs --tail 200 "${svc}" >&2 || true
      return 1
    fi
    sleep "${interval}"
  done
}

echo "Validating health..."
wait_for_health postgres 180
wait_for_health api 180
wait_for_health front 180
wait_for_health nginx 180

echo "OK. Production Postgres volume switched."
echo "FROM=${FROM_VOL}"
echo "TO=${TO_VOL}"
echo "Rollback (if needed): bash scripts/postgres-switch-volume.sh --to ${FROM_VOL}"
