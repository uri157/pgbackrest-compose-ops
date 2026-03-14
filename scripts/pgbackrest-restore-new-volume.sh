#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# scripts/pgbackrest-restore-new-volume.sh
#
# Restore pgBackRest backups into a NEW Postgres volume (parallel restore),
# then optionally boot a "shadow" Postgres container under a separate
# docker compose project so you can validate safely.
#
# FIXES (important):
# 1) --backup/--set is now independent from PITR targeting.
#    You can combine: --backup <set> --time <ts>  OR  --backup <set> --restore-point <name>
# 2) Prevent contradictory flags: --latest cannot be combined with --backup/--set.
# 3) Printed "shadow stack commands" no longer rely on the temp override file path
#    (since that file may be cleaned up on success).
# 4) "Silent restore": prevent contaminating the archive repo from shadow restores:
#    - pgBackRest restore uses --archive-mode=off
#    - shadow Postgres starts with archive_mode=off and archive_command=/bin/true
# ------------------------------------------------------------

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN:  $*" >&2; }
info() { echo "INFO:  $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/load-ops-config.sh
. "${SCRIPT_DIR}/lib/load-ops-config.sh"
load_ops_config "$SCRIPT_DIR"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$REPO_ROOT}"

COMPOSE_FILE_DEFAULT="${DEPLOY_DIR}/docker-compose.prod.yml"
STATE_DIR="${DEPLOY_DIR}/state"

ENV_API_FILE="${DEPLOY_DIR}/env/.env.api"
ENV_BACKUP_FILE="${DEPLOY_DIR}/env/.env.backup"

STANZA="${STANZA:-${PGBR_STANZA:-main}}"
PGBR_CONFIG_PATH="${PGBR_CONFIG:-/etc/pgbackrest/pgbackrest.conf}"
COMPOSE_FILE="$COMPOSE_FILE_DEFAULT"
RESTORE_PROJECT_PREFIX="${RESTORE_PROJECT_PREFIX:-pgbackrest-restore-}"
RESTORE_VOLUME_PREFIX="${RESTORE_VOLUME_PREFIX:-pgrestore_}"

# Base backup selection (optional)
BACKUP_SET=""
EXPLICIT_LATEST=0
EXPLICIT_SET=0

# PITR target (optional)
TARGET_TYPE=""   # "" | "time" | "name"
TARGET_VALUE=""

NEW_VOLUME=""
PROJECT=""
NO_START=0
NO_VALIDATE=0
DRY_RUN=0
FORCE=0

# auto-clean flags
KEEP_VOLUME_ON_FAIL=0   # if 1, won't delete the NEW_VOLUME even if created here

# internal tracking
OVERRIDE_FILE=""
CREATED_VOLUME=0

usage() {
  cat <<'HELP'
pgBackRest: Restore to new volume (parallel)

USAGE
  bash scripts/pgbackrest-restore-new-volume.sh [options]

BASE BACKUP SELECTION (optional)
  --latest                    Use latest backup set (default if no --backup/--set is provided)
  --set <backup_set>          Use a specific backup set (full or diff)
  --backup <backup_set>       Alias of --set

PITR TARGETING (optional)
  --time <timestamp>          Target restore to a timestamp (PITR)
  --restore-point <name>      Target restore to a Postgres restore point name

NOTE: You MAY combine a base set with PITR targeting:
  --backup <set> --time "<ts>"
  --backup <set> --restore-point "<name>"
If no --backup is given, pgBackRest will use the latest backup set as the base.

OPTIONS
  --new-volume <volume_name>
  --to <volume_name>           Alias of --new-volume
  --project <compose_project_name>
  --stanza <stanza>
  --compose-file <path>
  --no-start
  --no-validate
  --force
  --dry-run
  --keep-volume-on-fail        Keep restored volume even if the script fails
  -h, --help

NOTES
- Uses --project-directory so it does NOT depend on where you run the script from.
- On failure, it cleans up shadow containers/networks/aux volumes it created.
- It deletes the NEW volume only if it was created by this script (and keep-volume-on-fail is not set).
- Timestamp strings with spaces MUST be quoted, e.g.:
    --time "2026-02-02 04:35:29.468074+00"
- This script ALWAYS runs shadow restores in "silent mode":
    * pgBackRest restore: --archive-mode=off
    * shadow Postgres:   archive_mode=off + archive_command=/bin/true
HELP
}

sanitize_name() {
  local s="$1"
  s="$(echo "$s" | tr '[:upper:]' '[:lower:]')"
  s="$(echo "$s" | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//; s/--+/-/g')"
  echo "$s"
}

print_cmd() { printf '+ '; printf '%q ' "$@"; printf '\n'; }

run_docker() {
  if [ "$DRY_RUN" -eq 1 ]; then print_cmd docker "$@"; return 0; fi
  docker "$@"
}

# Build an override that guarantees postgres gets the backup envs for WAL recovery
# AND starts in "silent" mode (no archive-push to repo).
make_override() {
  local tmp
  tmp="$(mktemp -p "$STATE_DIR" "shadow-override-${PROJECT}-XXXX.yml")"

  {
    echo "services:"
    echo "  postgres:"
    echo "    env_file:"
    if [ -f "$ENV_API_FILE" ]; then
      echo "      - $ENV_API_FILE"
    else
      warn "Missing $ENV_API_FILE (postgres envs may be incomplete)"
    fi
    if [ -f "$ENV_BACKUP_FILE" ]; then
      echo "      - $ENV_BACKUP_FILE"
    else
      warn "Missing $ENV_BACKUP_FILE (WAL recovery may fail)"
    fi

    # Force shadow postgres to NEVER archive-push anything.
    # This prevents writing timeline/WAL artifacts into the repo from test restores.
    echo "    command:"
    echo "      - postgres"
    echo "      - -c"
    echo "      - archive_mode=off"
    echo "      - -c"
    echo "      - archive_command=/bin/true"
  } > "$tmp"

  OVERRIDE_FILE="$tmp"
  info "Using shadow override: $OVERRIDE_FILE"
}

compose() {
  POSTGRES_VOLUME="$NEW_VOLUME" \
  API_TAG="${API_TAG:-latest}" \
  MIGRATOR_TAG="${MIGRATOR_TAG:-latest}" \
  FRONT_TAG="${FRONT_TAG:-latest}" \
  CLOUDFLARED_TOKEN="${CLOUDFLARED_TOKEN:-${TUNNEL_TOKEN:-__unused__}}" \
  TUNNEL_TOKEN="${TUNNEL_TOKEN:-${CLOUDFLARED_TOKEN:-__unused__}}" \
  docker compose \
    --project-directory "$DEPLOY_DIR" \
    -p "$PROJECT" \
    -f "$COMPOSE_FILE" \
    ${OVERRIDE_FILE:+-f "$OVERRIDE_FILE"} \
    "$@"
}

run_compose() {
  if [ "$DRY_RUN" -eq 1 ]; then
    print_cmd docker compose --project-directory "$DEPLOY_DIR" -p "$PROJECT" -f "$COMPOSE_FILE" ${OVERRIDE_FILE:+-f "$OVERRIDE_FILE"} "$@"
    return 0
  fi
  compose "$@"
}

run_compose_stdin_null() {
  if [ "$DRY_RUN" -eq 1 ]; then
    print_cmd docker compose --project-directory "$DEPLOY_DIR" -p "$PROJECT" -f "$COMPOSE_FILE" ${OVERRIDE_FILE:+-f "$OVERRIDE_FILE"} "$@"
    echo "+ (stdin) </dev/null"
    return 0
  fi
  compose "$@" </dev/null
}

append_log() {
  local msg="$1"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "${ts} | restore_to_new_volume | project=${PROJECT} | volume=${NEW_VOLUME} | ${msg}" >> "${STATE_DIR}/restores.log"
}

volume_exists() {
  docker volume inspect "$1" >/dev/null 2>&1
}

pick_local_image() {
  local candidates=()
  if [ -n "${PGBR_POSTGRES_IMAGE:-}" ]; then
    candidates+=( "${PGBR_POSTGRES_IMAGE}" )
  fi
  candidates+=(
    "postgres:16-alpine"
    "public.ecr.aws/docker/library/postgres:16-alpine"
    "public.ecr.aws/docker/library/busybox:1.36"
    "busybox:1.36"
    "alpine:3.20"
  )

  for img in "${candidates[@]}"; do
    if docker image inspect "$img" >/dev/null 2>&1; then
      echo "$img"
      return 0
    fi
  done
  return 1
}

volume_is_empty() {
  local vol="$1"
  local img
  img="$(pick_local_image)" || die "No local image available to check volume emptiness."
  docker run --rm -v "${vol}:/v" "$img" sh -c 'test -z "$(ls -A /v 2>/dev/null || true)"'
}

wait_for_health() {
  local svc="$1"
  local timeout="${2:-180}"
  local interval=5
  local start now cid health

  start="$(date +%s)"
  while true; do
    cid="$(compose ps -q "$svc" 2>/dev/null || true)"
    if [ -n "$cid" ]; then
      health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || true)"
      case "$health" in
        healthy) info "$svc is healthy"; return 0 ;;
        unhealthy) compose logs --tail 200 "$svc" >&2 || true; die "$svc is unhealthy" ;;
        none) ;;
      esac
    fi

    now="$(date +%s)"
    if [ $((now - start)) -ge "$timeout" ]; then
      compose logs --tail 200 "$svc" >&2 || true
      die "Timeout waiting for $svc health"
    fi
    sleep "$interval"
  done
}

psql_exec() {
  local sql="$1"
  compose exec -T postgres sh -c '
    : "${POSTGRES_USER:?missing POSTGRES_USER}";
    : "${POSTGRES_DB:?missing POSTGRES_DB}";
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -c "'"$sql"'"
  ' </dev/null
}

cleanup_on_exit() {
  local code="$1"
  set +e

  # success: remove override temp file (and do NOT print commands relying on it)
  if [ "$code" -eq 0 ]; then
    if [ -n "${OVERRIDE_FILE:-}" ] && [ -f "$OVERRIDE_FILE" ]; then
      rm -f "$OVERRIDE_FILE" >/dev/null 2>&1 || true
    fi
    return 0
  fi

  # dry-run: don't delete anything
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    return 0
  fi

  warn "Script failed (exit=$code). Cleaning shadow resources for project=$PROJECT ..."

  # stop/remove containers + network
  compose down --remove-orphans >/dev/null 2>&1 || true

  # ensure no leftover containers keep the restored volume busy
  docker ps -a -q --filter "volume=${NEW_VOLUME}" | xargs -r docker rm -f >/dev/null 2>&1 || true

  # remove compose-created helper volumes (pgbackrest logs, sockets, etc.)
  docker volume ls -q --filter "label=com.docker.compose.project=${PROJECT}" | xargs -r docker volume rm >/dev/null 2>&1 || true

  # remove compose-created networks
  docker network ls -q --filter "label=com.docker.compose.project=${PROJECT}" | xargs -r docker network rm >/dev/null 2>&1 || true

  # remove restored volume only if created here (and not asked to keep)
  if [ "${CREATED_VOLUME:-0}" -eq 1 ] && [ "${KEEP_VOLUME_ON_FAIL:-0}" -eq 0 ]; then
    docker volume rm "${NEW_VOLUME}" >/dev/null 2>&1 || true
    info "Removed restored volume (created by script): ${NEW_VOLUME}"
  else
    warn "Keeping restored volume: ${NEW_VOLUME} (created_volume=${CREATED_VOLUME}, keep_on_fail=${KEEP_VOLUME_ON_FAIL})"
  fi

  # remove override temp file last
  if [ -n "${OVERRIDE_FILE:-}" ] && [ -f "$OVERRIDE_FILE" ]; then
    rm -f "$OVERRIDE_FILE" >/dev/null 2>&1 || true
  fi
}

trap 'cleanup_on_exit $?' EXIT

# -----------------------------
# arg parsing
# -----------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    # Base selection
    --latest)
      EXPLICIT_LATEST=1
      BACKUP_SET=""
      shift
      ;;
    --set|--backup)
      [ $# -ge 2 ] || die "$1 requires an argument"
      EXPLICIT_SET=1
      BACKUP_SET="$2"
      shift 2
      ;;

    # PITR targeting
    --restore-point)
      [ $# -ge 2 ] || die "--restore-point requires an argument"
      if [ -n "$TARGET_TYPE" ] && [ "$TARGET_TYPE" != "name" ]; then
        die "You can't combine --restore-point with --time"
      fi
      TARGET_TYPE="name"
      TARGET_VALUE="$2"
      shift 2
      ;;
    --time)
      [ $# -ge 2 ] || die "--time requires an argument"
      if [ -n "$TARGET_TYPE" ] && [ "$TARGET_TYPE" != "time" ]; then
        die "You can't combine --time with --restore-point"
      fi
      TARGET_TYPE="time"
      TARGET_VALUE="$2"
      shift 2
      ;;

    # Generic options
    --new-volume|--to)
      [ $# -ge 2 ] || die "$1 requires an argument"
      NEW_VOLUME="$2"; shift 2
      ;;
    --project)
      [ $# -ge 2 ] || die "--project requires an argument"
      PROJECT="$2"; shift 2
      ;;
    --stanza)
      [ $# -ge 2 ] || die "--stanza requires an argument"
      STANZA="$2"; shift 2
      ;;
    --compose-file)
      [ $# -ge 2 ] || die "--compose-file requires an argument"
      COMPOSE_FILE="$2"; shift 2
      ;;
    --no-start) NO_START=1; shift ;;
    --no-validate) NO_VALIDATE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    --keep-volume-on-fail) KEEP_VOLUME_ON_FAIL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown arg: $1 (use --help)" ;;
  esac
done

# Validation of contradictory flags
if [ "$EXPLICIT_LATEST" -eq 1 ] && [ "$EXPLICIT_SET" -eq 1 ]; then
  die "Don't combine --latest with --backup/--set. Pick one."
fi

# If --latest not explicitly set and no --set provided, we behave as latest (default).
# (No action needed; BACKUP_SET empty implies latest base.)

[ -f "$COMPOSE_FILE" ] || die "Compose file not found: $COMPOSE_FILE"

mkdir -p "$STATE_DIR"
touch "${STATE_DIR}/restores.log" || true
chmod 700 "$STATE_DIR" 2>/dev/null || true
chmod 600 "${STATE_DIR}/restores.log" 2>/dev/null || true

# Use digits-only timestamp to avoid invalid compose project names
UTC_TS="$(date -u +%Y%m%d%H%M%S)"

if [ -z "$PROJECT" ]; then
  PROJECT="${RESTORE_PROJECT_PREFIX}${UTC_TS}"
fi
if [ -z "$NEW_VOLUME" ]; then
  NEW_VOLUME="${RESTORE_VOLUME_PREFIX}${UTC_TS}"
fi

PROJECT="$(sanitize_name "$PROJECT")"
NEW_VOLUME="$(sanitize_name "$NEW_VOLUME")"

[ -n "$PROJECT" ] || die "Invalid project name after sanitization"
[ -n "$NEW_VOLUME" ] || die "Invalid volume name after sanitization"

# -----------------------------
# pre-flight
# -----------------------------
info "Restore project: $PROJECT"
info "New volume:      $NEW_VOLUME"
info "Compose file:    $COMPOSE_FILE"
info "Stanza:          $STANZA"
if [ -n "$BACKUP_SET" ]; then
  info "Backup set:      $BACKUP_SET"
else
  info "Backup set:      (latest)"
fi
if [ -n "$TARGET_TYPE" ]; then
  info "Target:          type=$TARGET_TYPE value=$TARGET_VALUE"
else
  info "Target:          (none)"
fi
info "Silent restore:  archive-mode=off (shadow will NOT archive-push)"

make_override

if volume_exists "$NEW_VOLUME"; then
  if [ "$FORCE" -eq 0 ]; then
    die "Volume already exists: $NEW_VOLUME (use --force if you know what you're doing)"
  fi
  info "Volume exists, checking if empty..."
  if [ "$DRY_RUN" -eq 1 ]; then
    print_cmd volume_is_empty "$NEW_VOLUME"
  else
    volume_is_empty "$NEW_VOLUME" || die "Volume is NOT empty: $NEW_VOLUME (refusing to restore into non-empty volume)"
  fi
else
  info "Creating docker volume: $NEW_VOLUME"
  run_docker volume create "$NEW_VOLUME" >/dev/null
  CREATED_VOLUME=1
fi

# -----------------------------
# restore args for pgbackrest
# -----------------------------
RESTORE_ARGS=( "--stanza=${STANZA}" "--config=${PGBR_CONFIG_PATH}" "restore" )

# CRITICAL: Do NOT allow the restored cluster to archive-push into repo.
# This avoids polluting repo with timelines/WAL from shadow restores.
RESTORE_ARGS+=( "--archive-mode=off" )

# Let pgBackRest write a valid restore_command into postgresql.auto.conf
RESTORE_ARGS+=( "--recovery-option=restore_command=pgbackrest-env --config=${PGBR_CONFIG_PATH} --stanza=${STANZA} archive-get %f %p" )

RESTORE_ARGS+=( "--target-timeline=current" )

# Base backup set (optional)
if [ -n "$BACKUP_SET" ]; then
  RESTORE_ARGS+=( "--set=${BACKUP_SET}" )
fi

# PITR target (optional)
case "$TARGET_TYPE" in
  "")
    ;;
  "name")
    [ -n "$TARGET_VALUE" ] || die "Missing --restore-point value"
    RESTORE_ARGS+=( "--type=name" "--target=${TARGET_VALUE}" "--target-action=promote" )
    ;;
  "time")
    [ -n "$TARGET_VALUE" ] || die "Missing --time value"
    RESTORE_ARGS+=( "--type=time" "--target=${TARGET_VALUE}" "--target-action=promote" )
    ;;
  *)
    die "Unknown TARGET_TYPE: $TARGET_TYPE"
    ;;
esac

append_log "begin backup_set=${BACKUP_SET:-latest} target_type=${TARGET_TYPE:-none} target=${TARGET_VALUE:-none} silent_archive=1"

# -----------------------------
# run restore (no deps)
# -----------------------------
info "Running pgBackRest restore into volume..."
run_compose_stdin_null run --rm -T --no-deps pgbackrest pgbackrest-env "${RESTORE_ARGS[@]}"

append_log "restore_complete"

if [ "$NO_START" -eq 1 ]; then
  info "Restore finished. (--no-start) Not starting shadow postgres."
  append_log "end no_start=1"
  exit 0
fi

# -----------------------------
# start shadow postgres
# -----------------------------
info "Starting shadow postgres (isolated stack)..."
run_compose up -d --no-deps postgres >/dev/null

wait_for_health postgres 240

if [ "$NO_VALIDATE" -eq 0 ]; then
  info "Validation: pg_isready + basic sanity queries"

  if [ "$DRY_RUN" -eq 1 ]; then
    print_cmd compose exec -T postgres sh -c 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
  else
    compose exec -T postgres sh -c 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"' </dev/null >/dev/null
  fi

  tbl_count=""
  if [ "$DRY_RUN" -eq 1 ]; then
    print_cmd psql_exec "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema');"
    tbl_count="(dry-run)"
  else
    tbl_count="$(psql_exec "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema');")"
  fi
  info "Table count (non-system schemas): ${tbl_count}"

  if [ "$DRY_RUN" -eq 0 ]; then
    if [ "${tbl_count:-0}" -lt 10 ]; then
      warn "Table count < 10. Might be OK (empty DB), but verify before switching."
    fi
  fi

  rec=""
  if [ "$DRY_RUN" -eq 1 ]; then
    print_cmd psql_exec "select pg_is_in_recovery();"
    rec="(dry-run)"
  else
    rec="$(psql_exec "select pg_is_in_recovery();")"
  fi
  info "pg_is_in_recovery(): ${rec}"

  if [ "$DRY_RUN" -eq 0 ]; then
    # Confirm shadow is not archiving (defensive check)
    amode="$(psql_exec "show archive_mode;")"
    acmd="$(psql_exec "show archive_command;")"
    info "shadow archive_mode: ${amode}"
    info "shadow archive_command: ${acmd}"
  fi
fi

append_log "end ok"
info "DONE."
info "Shadow stack commands (override file NOT needed for ps/logs/down):"
echo "  docker compose --project-directory \"$DEPLOY_DIR\" -p \"$PROJECT\" -f \"$COMPOSE_FILE\" ps"
echo "  docker compose --project-directory \"$DEPLOY_DIR\" -p \"$PROJECT\" -f \"$COMPOSE_FILE\" logs -f postgres"
echo "  docker compose --project-directory \"$DEPLOY_DIR\" -p \"$PROJECT\" -f \"$COMPOSE_FILE\" down"
echo "  docker volume ls | grep \"$NEW_VOLUME\""
