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
PGBACKREST_SERVICE="${PGBACKREST_SERVICE:-pgbackrest}"

usage() {
  echo "Usage: $0 [full|diff]" >&2
}

backup_type="${1:-diff}"
case "$backup_type" in
  full|diff)
    ;;
  *)
    usage
    exit 1
    ;;
esac

compose() {
  if [ -n "${COMPOSE_ENV_FILE:-}" ] && [ -f "$COMPOSE_ENV_FILE" ]; then
    docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" "$@"
  else
    docker compose -f "$COMPOSE_FILE" "$@"
  fi
}

compose up -d "$PGBACKREST_SERVICE"
compose exec -T "$PGBACKREST_SERVICE" pgbackrest-env --stanza="$STANZA" backup --type="$backup_type"
