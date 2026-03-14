#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/load-ops-config.sh
. "${SCRIPT_DIR}/lib/load-ops-config.sh"
load_ops_config "$SCRIPT_DIR"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$REPO_ROOT}"
COMPOSE_FILE="${COMPOSE_FILE:-$DEPLOY_DIR/docker-compose.prod.yml}"
STANZA="${PGBACKREST_STANZA:-${PGBR_STANZA:-main}}"
CONFIG_PATH="${PGBACKREST_CONFIG:-${PGBR_CONFIG:-/etc/pgbackrest/pgbackrest.conf}}"
PGBACKREST_SERVICE="${PGBACKREST_SERVICE:-pgbackrest}"

if [ ! -f "$COMPOSE_FILE" ]; then
  COMPOSE_FILE="${SCRIPT_DIR}/../docker-compose.prod.yml"
fi

docker compose -f "$COMPOSE_FILE" up -d "$PGBACKREST_SERVICE"
docker compose -f "$COMPOSE_FILE" exec -T "$PGBACKREST_SERVICE" \
  pgbackrest-env --stanza="$STANZA" --config="$CONFIG_PATH" expire
docker compose -f "$COMPOSE_FILE" exec -T "$PGBACKREST_SERVICE" \
  pgbackrest-env --stanza="$STANZA" --config="$CONFIG_PATH" check
