#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/load-ops-config.sh
. "${SCRIPT_DIR}/lib/load-ops-config.sh"
load_ops_config "$SCRIPT_DIR"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$REPO_ROOT}"
COMPOSE_FILE="${COMPOSE_FILE:-${DEPLOY_DIR}/docker-compose.prod.yml}"
COMPOSE_ENV_FILE="${COMPOSE_ENV_FILE:-${COMPOSE_ENV:-}}"
STANZA="${PGBACKREST_STANZA:-${PGBR_STANZA:-main}}"
PG_SERVICE="${PG_SERVICE:-postgres}"
PGBACKREST_SERVICE="${PGBACKREST_SERVICE:-pgbackrest}"
PGDATA_DIR="${PGDATA_DIR:-/var/lib/postgresql/data}"

usage() {
  echo "Usage: FORCE_RESTORE=1 $0 '<restore_point>'" >&2
  echo "Example: FORCE_RESTORE=1 $0 'pre_deploy_20240101T120000Z_abc123'" >&2
}

restore_point="${1:-}"
if [ -z "$restore_point" ]; then
  usage
  exit 1
fi

if [ "${FORCE_RESTORE:-}" != "1" ]; then
  echo "Refusing to run without FORCE_RESTORE=1" >&2
  echo "This will stop postgres and overwrite PGDATA." >&2
  exit 1
fi

compose() {
  if [ -n "${COMPOSE_ENV_FILE:-}" ] && [ -f "$COMPOSE_ENV_FILE" ]; then
    docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" "$@"
  else
    docker compose -f "$COMPOSE_FILE" "$@"
  fi
}

compose up -d "$PGBACKREST_SERVICE"
compose stop "$PG_SERVICE"

backup_suffix="$(date -u +%Y%m%d_%H%M%S)"
backup_path="${PGDATA_DIR}-backup-${backup_suffix}"
compose exec -T "$PGBACKREST_SERVICE" sh -c "if [ -d '${PGDATA_DIR}' ]; then mv '${PGDATA_DIR}' '${backup_path}'; fi; mkdir -p '${PGDATA_DIR}'"

compose exec -T "$PGBACKREST_SERVICE" pgbackrest-env --stanza="$STANZA" --type=name --target="$restore_point" --target-action=promote restore

compose up -d "$PG_SERVICE"

echo "Restore completed. Previous data moved to: ${backup_path}"
