#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# PITR restore to new volume + validate + optional cutover
# ------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/load-ops-config.sh
. "${SCRIPT_DIR}/lib/load-ops-config.sh"
load_ops_config "$SCRIPT_DIR"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$REPO_ROOT}"
ENV_DIR="${DEPLOY_DIR}/env"
STATE_DIR="${DEPLOY_DIR}/state"

COMPOSE_FILE="${COMPOSE_FILE:-${DEPLOY_DIR}/docker-compose.prod.yml}"
COMPOSE_ENV="${COMPOSE_ENV:-${ENV_DIR}/.env.compose}"
API_ENV="${API_ENV:-${ENV_DIR}/.env.api}"
BACKUP_ENV="${BACKUP_ENV:-${ENV_DIR}/.env.backup}"
DEPLOY_ENV="${DEPLOY_ENV:-${DEPLOY_DIR}/.env.deploy}"

PG_SERVICE="${PG_SERVICE:-postgres}"
PGBACKREST_SERVICE="${PGBACKREST_SERVICE:-pgbackrest}"
STANZA="${PGBR_STANZA:-main}"
PGBR_CONFIG_PATH="${PGBR_CONFIG:-/etc/pgbackrest/pgbackrest.conf}"
TARGET_NAME=""
CUTOVER="false"
TEST_PORT="15433"
MIN_PUBLIC_TABLES="10"
VOL_PREFIX="${VOL_PREFIX:-${RESTORE_VOLUME_PREFIX:-pgrestore}}"
KEEP_TEST="false"
POSTGRES_IMAGE="${PGBR_POSTGRES_IMAGE:-postgres:16-alpine}"
TEST_CONTAINER_PREFIX="${TEST_CONTAINER_PREFIX:-pgbackrest-restore-test}"
CUTOVER_SERVICES="${CUTOVER_SERVICES:-postgres pgbackrest}"
VOL_PREFIX="${VOL_PREFIX%_}"

usage() {
  cat <<EOF
Usage:
  $0 --target-name <restore_point_label> [options]

Options:
  --cutover                 Switch POSTGRES_VOLUME to restored volume and restart stack
  --test-port <port>        Local port for test postgres (default: ${TEST_PORT})
  --min-tables <n>          Min tables in public schema for validation (default: ${MIN_PUBLIC_TABLES})
  --vol-prefix <prefix>     Volume name prefix (default: ${VOL_PREFIX})
  --keep-test               Do not remove test container (default: false)

Examples:
  $0 --target-name pre_deploy_20260129T040000Z_ab12cd
  $0 --target-name pre_deploy_... --cutover
EOF
}

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --target-name) TARGET_NAME="${2:-}"; shift 2 ;;
    --cutover) CUTOVER="true"; shift 1 ;;
    --test-port) TEST_PORT="${2:-}"; shift 2 ;;
    --min-tables) MIN_PUBLIC_TABLES="${2:-}"; shift 2 ;;
    --vol-prefix) VOL_PREFIX="${2:-}"; shift 2 ;;
    --keep-test) KEEP_TEST="true"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown arg: $1" ;;
  esac
done

[ -n "$TARGET_NAME" ] || { usage; die "Missing --target-name"; }

[ -f "$COMPOSE_FILE" ] || die "Missing compose file: $COMPOSE_FILE"
[ -f "$COMPOSE_ENV" ] || die "Missing compose env: $COMPOSE_ENV (needs POSTGRES_VOLUME=...)"
[ -f "$API_ENV" ] || die "Missing api env: $API_ENV"
[ -f "$BACKUP_ENV" ] || die "Missing backup env: $BACKUP_ENV"

mkdir -p "$STATE_DIR"
touch "${STATE_DIR}/restores.log" "${STATE_DIR}/pgbackrest-info.log" || true
chmod 700 "$STATE_DIR" || true
chmod 600 "${STATE_DIR}/restores.log" "${STATE_DIR}/pgbackrest-info.log" || true

# Load current active volume from .env.compose
set -a
# shellcheck disable=SC1090
. "$COMPOSE_ENV"
set +a
[ -n "${POSTGRES_VOLUME:-}" ] || die "POSTGRES_VOLUME is empty in $COMPOSE_ENV"
OLD_VOL="$POSTGRES_VOLUME"

# Check port availability (best-effort)
if command -v ss >/dev/null 2>&1; then
  if ss -ltn | awk '{print $4}' | grep -qE ":${TEST_PORT}$"; then
    die "Test port ${TEST_PORT} is already in use. Use --test-port <other>."
  fi
fi

# Ensure postgres image exists (build if missing)
if ! docker image inspect "$POSTGRES_IMAGE" >/dev/null 2>&1; then
  log "Local image $POSTGRES_IMAGE missing, building via compose service $PG_SERVICE..."
  (cd "$DEPLOY_DIR" && docker compose -f "$COMPOSE_FILE" build --pull "$PG_SERVICE")
fi

ts_compact="$(date -u +%Y%m%d_%H%M%S)"
NEW_VOL="${VOL_PREFIX}_${ts_compact}"
TEST_CONTAINER="${TEST_CONTAINER_PREFIX}-${ts_compact}"

log "Active volume : ${OLD_VOL}"
log "New volume    : ${NEW_VOL}"
log "Target name   : ${TARGET_NAME}"
log "Test port     : 127.0.0.1:${TEST_PORT} -> 5432"
log "Min tables    : > ${MIN_PUBLIC_TABLES}"

log "Creating new volume..."
docker volume create "$NEW_VOL" >/dev/null

log "Logging pgBackRest info (host-side)..."
{
  echo "----- $(date -u +%Y-%m-%dT%H:%M:%SZ) -----"
  docker compose -f "$COMPOSE_FILE" exec -T "$PGBACKREST_SERVICE" pgbackrest-env \
    --stanza="$STANZA" --config="$PGBR_CONFIG_PATH" info </dev/null || true
  echo
} >> "${STATE_DIR}/pgbackrest-info.log"

log "Running pgBackRest restore into new volume..."
(
  cd "$DEPLOY_DIR"
  docker compose -f "$COMPOSE_FILE" run --rm -T \
    -v "${NEW_VOL}:/restore" \
    -v "${DEPLOY_DIR}/pgbackrest/pgbackrest.conf:${PGBR_CONFIG_PATH}:ro" \
    "$PGBACKREST_SERVICE" sh -lc "
      pgbackrest-env --stanza=${STANZA} --config=${PGBR_CONFIG_PATH} \
        restore --pg1-path=/restore \
        --type=name --target=\"${TARGET_NAME}\" \
        --recovery-option=\"restore_command=pgbackrest-env --stanza=${STANZA} --config=${PGBR_CONFIG_PATH} --pg1-path=/restore archive-get \\\"%f\\\" \\\"%p\\\"\" \
        --recovery-option=\"recovery_target_action=promote\"
    "
)

log "Starting test postgres container..."
docker run -d --name "$TEST_CONTAINER" \
  --env-file "$API_ENV" \
  --env-file "$BACKUP_ENV" \
  -e PGDATA=/restore \
  -e PGBACKREST_PG1_PATH=/restore \
  -v "${NEW_VOL}:/restore" \
  -v "${DEPLOY_DIR}/pgbackrest/pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro" \
  -v "${DEPLOY_DIR}/postgres/postgresql.conf:/etc/postgresql/postgresql.conf:ro" \
  -v "${DEPLOY_DIR}/postgres/conf.d:/etc/postgresql/conf.d:ro" \
  -p "127.0.0.1:${TEST_PORT}:5432" \
  "$POSTGRES_IMAGE" \
  postgres -c "config_file=/etc/postgresql/postgresql.conf" -c "listen_addresses=*"

# Wait until ready
log "Waiting for test postgres to be ready..."
deadline=$(( $(date +%s) + 120 ))
until docker exec -T "$TEST_CONTAINER" sh -lc 'pg_isready -h /var/run/postgresql -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1'; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    docker logs "$TEST_CONTAINER" --tail 200 >&2 || true
    die "Timeout waiting test postgres"
  fi
  sleep 3
done

log "Running validations..."
recovery_flag="$(docker exec -T "$TEST_CONTAINER" sh -lc \
  'psql -h /var/run/postgresql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT pg_is_in_recovery();"' \
)"
[ "$recovery_flag" = "f" ] || die "Validation failed: pg_is_in_recovery() returned '${recovery_flag}'"

public_tables="$(docker exec -T "$TEST_CONTAINER" sh -lc \
  'psql -h /var/run/postgresql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "
    SELECT count(*)
    FROM pg_class c
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE c.relkind='\''r'\'' AND n.nspname='\''public'\'';
  "' \
)"
# numeric compare
if ! [ "$public_tables" -gt "$MIN_PUBLIC_TABLES" ]; then
  die "Validation failed: public tables (${public_tables}) is not > ${MIN_PUBLIC_TABLES}"
fi

log "OK: validations passed (recovery=f, public_tables=${public_tables}) ✅"

# Stop test container (clean)
log "Stopping test container..."
docker stop "$TEST_CONTAINER" >/dev/null

if [ "$KEEP_TEST" != "true" ]; then
  docker rm "$TEST_CONTAINER" >/dev/null || true
fi

# Log restore attempt
{
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | restore_ok | target=${TARGET_NAME} | old_vol=${OLD_VOL} | new_vol=${NEW_VOL} | public_tables=${public_tables}"
} >> "${STATE_DIR}/restores.log"

if [ "$CUTOVER" != "true" ]; then
  log "Cutover not requested. New volume is ready: ${NEW_VOL}"
  log "If you want to cutover later:"
  log "  1) set POSTGRES_VOLUME=${NEW_VOL} in ${COMPOSE_ENV}"
  log "  2) docker compose -f ${COMPOSE_FILE} up -d --force-recreate ${CUTOVER_SERVICES}"
  exit 0
fi

log "CUTOVER requested. Switching POSTGRES_VOLUME -> ${NEW_VOL}"

# Update .env.compose atomically
tmpfile="$(mktemp)"
{
  echo "POSTGRES_VOLUME=${NEW_VOL}"
} > "$tmpfile"
mv "$tmpfile" "$COMPOSE_ENV"
chmod 600 "$COMPOSE_ENV" || true

# Export envs for compose interpolation
set -a
# shellcheck disable=SC1090
. "$COMPOSE_ENV"
[ -f "$DEPLOY_ENV" ] && . "$DEPLOY_ENV" || true
set +a

# Restart stack (no migrator)
log "Restarting stack with new volume..."
(
  cd "$DEPLOY_DIR"
  docker compose -f "$COMPOSE_FILE" up -d --force-recreate ${CUTOVER_SERVICES}
)

log "Cutover done ✅"
log "Old volume kept as rollback/quarantine: ${OLD_VOL}"
log "Active volume is now: ${NEW_VOL}"
