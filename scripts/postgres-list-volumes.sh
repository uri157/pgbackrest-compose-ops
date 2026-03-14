#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/load-ops-config.sh
. "${SCRIPT_DIR}/lib/load-ops-config.sh"
load_ops_config "$SCRIPT_DIR"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BASE_DIR="${DEPLOY_DIR:-$REPO_ROOT}"
COMPOSE_ENV="${BASE_DIR}/env/.env.compose"
VOLUME_LIST_REGEX="${VOLUME_LIST_REGEX:-postgres|pgbackrest|pgdata|restore}"

PROD_VOLUME=""
if [ -f "$COMPOSE_ENV" ]; then
  PROD_VOLUME="$(grep -E '^POSTGRES_VOLUME=' "$COMPOSE_ENV" | cut -d= -f2 || true)"
fi

echo "========================================"
echo " Postgres Volumes"
echo "========================================"
[ -n "$PROD_VOLUME" ] && echo "Current PROD volume: ${PROD_VOLUME}" || echo "Current PROD volume: <unknown>"
echo

mapfile -t VOLUMES < <(docker volume ls --format '{{.Name}}' | grep -E "$VOLUME_LIST_REGEX" | sort || true)

if [ "${#VOLUMES[@]}" -eq 0 ]; then
  echo "No matching volumes found."
  exit 0
fi

for vol in "${VOLUMES[@]}"; do
  mark=" "
  [ "$vol" = "$PROD_VOLUME" ] && mark="*"

  users="$(docker ps -a --filter volume="$vol" --format '{{.Names}}' | tr '\n' ',' | sed 's/,$//' || true)"
  if [ -z "$users" ]; then
    users="free"
  fi

  printf "%s %-45s [%s]\n" "$mark" "$vol" "$users"
done

echo
echo "* = production volume"
