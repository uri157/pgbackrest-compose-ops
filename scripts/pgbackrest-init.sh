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
WAIT_TIMEOUT="${WAIT_TIMEOUT:-120}"

compose() {
  if [ -n "${COMPOSE_ENV_FILE:-}" ] && [ -f "$COMPOSE_ENV_FILE" ]; then
    docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" "$@"
  else
    docker compose -f "$COMPOSE_FILE" "$@"
  fi
}

compose up -d "$PG_SERVICE" "$PGBACKREST_SERVICE"

start_time="$(date +%s)"
while true; do
  if compose exec -T "$PG_SERVICE" sh -c 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null 2>&1; then
    echo "postgres is ready"
    break
  fi

  now="$(date +%s)"
  if [ $((now - start_time)) -ge "$WAIT_TIMEOUT" ]; then
    echo "Timeout waiting for postgres" >&2
    compose logs --tail 200 "$PG_SERVICE" >&2 || true
    exit 1
  fi
  sleep 5
done

if compose exec -T "$PGBACKREST_SERVICE" pgbackrest-env --stanza="$STANZA" info >/dev/null 2>&1; then
  echo "Stanza $STANZA already exists"
else
  compose exec -T "$PGBACKREST_SERVICE" pgbackrest-env --stanza="$STANZA" stanza-create
fi

compose exec -T "$PGBACKREST_SERVICE" pgbackrest-env --stanza="$STANZA" check
